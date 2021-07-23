{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost        #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Language.PureScript.Interpreter
  ( 
  -- * High-level API
    interpret
  , builtIn
  
  -- * Evaluation
  -- ** Representation of values
  , Value(..)
  
  -- ** Evaluation monad
  , EvalT(..)
  , Eval
  , runEval
  , EvaluationError(..)
  , renderEvaluationError
  
  -- ** Eval/apply
  , Env
  , eval
  , apply
  
  -- * Conversion to and from Haskell types
  , ToValue(..)
  , FromValue(..)
  -- ** Higher-order functions
  , ToValueRHS(..)
  , FromValueRHS(..)
  -- ** Records
  , GToObject(..)
  , GFromObject(..)
  ) where
 
import Control.Monad (guard, foldM, join, mzero, zipWithM)
import Control.Monad.Error.Class (MonadError, throwError)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Align qualified as Align
import Data.Foldable (asum, fold)
import Data.Functor (void)
import Data.Functor.Identity (Identity(..))
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Proxy (Proxy(..))
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.These (These(..))
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics qualified as G
import GHC.TypeLits (KnownSymbol, symbolVal)
import Language.PureScript.CoreFn qualified as CoreFn
import Language.PureScript.Names (Ident(..), Qualified(..))
import Language.PureScript.Names qualified as Names
import Language.PureScript.PSString qualified as PSString

-- | Evaluate a compiled PureScript module in the specified environment,
-- returning the output from its main function as a Haskell value.
interpret :: FromValue m a => Env m -> CoreFn.Module ann -> EvalT m a
interpret initialEnv CoreFn.Module{ CoreFn.moduleName, CoreFn.moduleDecls } = do
  env <- bind moduleName (Just moduleName) initialEnv (fmap void moduleDecls)
  mainFn <- eval moduleName env (CoreFn.Var () (Qualified (Just moduleName) (Ident "main")))
  fromValue mainFn

-- | Create an environment from a Haskell value.
--
-- It is recommended that a type annotation is given for the type of the value
-- being provided.
--
-- For example:
--
-- @
--    builtIn "greeting" ("Hello, World!" :: Text)
--    builtIn "somePrimes" ([2, 3, 5, 7, 11] :: Vector Integer)
-- @
--
-- Functions can be provided as built-ins, but the 'EvalT' monad needs to be
-- used to wrap any outputs (or values in positive position):
--
-- @
--    builtIn "strip" ((pure . Text.strip) :: Text -> EvalT m Text)
--    builtIn "map" (traverse :: (Value -> EvalT m Value) -> Vector Value -> EvalT m (Vector Value))
-- @
--
-- Polymorphic functions can also be provided as built-ins, but values with 
-- polymoprhic types will need to be passed across the FFI boundary with 
-- monomorphic types. The type 'Value' can always be used to represent values of
-- unknown or polymorphic type, as in the @map@ example above.
builtIn :: ToValue m a => Text -> a -> Env m
builtIn name value =
  let qualName = Names.mkQualified (Names.Ident name) (Names.ModuleName "Main")
   in Map.singleton qualName $ toValue value

-- | The representation of values used by the interpreter - essentially, the
-- semantic domain for a simple untyped lambda calculus with records and ADTs.
--
-- Any additional side effects which might occur in FFI calls to Haskell code
-- are tracked by a monad in the type argument.
data Value m
  = Object (HashMap Text (Value m))
  -- ^ Records are represented as hashmaps from their field names to values
  | Array (Vector (Value m))
  -- ^ Arrays
  | String Text
  | Number Scientific
  -- ^ Numeric values
  -- 
  -- TODO: separate integers from floating-point values
  | Bool Bool
  | Closure (Value m -> EvalT m (Value m))
  -- ^ Closures, represented in higher-order abstract syntax style.
  | Constructor (Qualified (Names.ProperName 'Names.ConstructorName)) [Value m]
  -- ^ Fully-applied data constructors

-- | An environment, i.e. a mapping from names to evaluated values.
--
-- An environment for a single built-in function can be constructed
-- using the 'builtIn' function, and environments can be combined
-- easily using the 'Monoid' instance for 'Map'.
type Env m = Map (Qualified Ident) (Value m)

-- | The monad used by the interpreter, which supports error reporting for errors
-- which can occur during evaluation.
--
-- The transformed monad is used to track any benign side effects that might be
-- exposed via the foreign function interface to PureScript code.
newtype EvalT m a = EvalT { runEvalT :: ExceptT EvaluationError m a }
  deriving newtype (Functor, Applicative, Monad, MonadError EvaluationError)

-- | Non-transformer version of `EvalT`, useful in any settings where the FFI
-- does not use any side effects during evaluation.
type Eval = EvalT Identity

runEval :: Eval a -> Either EvaluationError a
runEval = runIdentity . runExceptT . runEvalT

-- | Errors which can occur during evaluation of PureScript code.
-- 
-- PureScript is a typed language, and tries to prevent runtime errors.
-- However, in the context of this interpreter, we can receive data from outside
-- PureScript code, so it is possible that runtime errors can occur if we are
-- not careful. This is similar to how PureScript code can fail at runtime
-- due to errors in the FFI.
data EvaluationError 
  = UnknownIdent (Qualified Ident)
  -- ^ A name was not found in the environment
  | TypeMismatch Text
  -- ^ The runtime representation of a value did not match the expected
  -- representation
  | FieldNotFound Text
  -- ^ A record field did not exist in an 'Object' value.
  | InexhaustivePatternMatch
  -- ^ A pattern match failed to match its argument
  | InvalidNumberOfArguments Int Int
  -- ^ A pattern match received the wrong number of arguments
  | UnsaturatedConstructorApplication
  -- ^ A pattern match occurred against a partially-applied data constructor
  | InvalidFieldName PSString.PSString
  -- ^ A PureScript string which contains lone surrogates which could not be
  -- decoded. See 'PSString.PSString'.
  | NotSupported Text 
  -- ^ A feature of the language is not yet implemented in the interpreter.
  --
  -- TODO: remove this once all features are supported
  | OtherError Text
  -- ^ An error occurred in a foreign function which is not tracked by
  -- any of the other error types.
  --
  -- TODO: remove this in favor of using monadic FFI functions

-- | Render an 'EvaluationError' as a human-readable string.
renderEvaluationError :: EvaluationError -> String
renderEvaluationError (UnknownIdent x) =
  "Identifier not in scope: " <> Text.unpack (Names.showQualified Names.showIdent x)
renderEvaluationError (TypeMismatch x) =
  "Type mismatch, expected " <> Text.unpack x
renderEvaluationError (FieldNotFound x) =
  "Record field not found: " <> Text.unpack x
renderEvaluationError InexhaustivePatternMatch =
  "Inexhaustive pattern match"
renderEvaluationError (InvalidNumberOfArguments given expected) =
  "Invalid number of arguments, given " <> show given <> ", but expected " <> show expected
renderEvaluationError UnsaturatedConstructorApplication =
  "Unsaturated constructor application"
renderEvaluationError (InvalidFieldName x) =
  "Invalid field name: " <> PSString.decodeStringWithReplacement x
renderEvaluationError (NotSupported x) =
  "Unsupported feature: " <> Text.unpack x
renderEvaluationError (OtherError x) =
  "Other error: " <> Text.unpack x

evalPSString :: Monad m => PSString.PSString -> EvalT m Text
evalPSString pss = 
  case PSString.decodeString pss of
    Just field -> pure field
    _ -> throwError (InvalidFieldName pss)

-- | Evaluate a PureScript CoreFn expression in the given environment.
--
-- Note: it should not be necessary to call this function directly in most
-- circumstances. It is provided as a helper function, for some more advanced
-- use cases, such as setting up a custom environment.
eval 
  :: forall m
   . Monad m
  => Names.ModuleName
  -> Env m
  -> CoreFn.Expr ()
  -> EvalT m (Value m)
eval mn env (CoreFn.Literal _ lit) =
  evalLit mn env lit
eval mn env (CoreFn.Accessor _ pss e) = do
  val <- eval mn env e
  field <- evalPSString pss
  case val of
    Object o ->
      case HashMap.lookup field o of
        Just x -> pure x
        Nothing -> throwError (FieldNotFound field)
    _ -> throwError (TypeMismatch "object")
eval mn env (CoreFn.Abs _ arg body) =
  pure . Closure $ \v -> eval mn (Map.insert (Qualified Nothing arg) v env) body
eval mn env (CoreFn.App _ f x) =
  join (apply <$> eval mn env f <*> eval mn env x)
eval _ env (CoreFn.Var _ name) =
  case Map.lookup name env of
    Nothing -> throwError $ UnknownIdent name
    Just val -> pure val
eval mn env (CoreFn.Let _ binders body) = do
  env' <- bind mn Nothing env binders
  eval mn env' body
eval mn env (CoreFn.ObjectUpdate _ e updates) = do
  val <- eval mn env e
  let updateOne 
        :: HashMap Text (Value m)
        -> (PSString.PSString, CoreFn.Expr ())
        -> EvalT m (HashMap Text (Value m))
      updateOne o (pss, new) = do
        field <- evalPSString pss
        newVal <- eval mn env new
        pure $ HashMap.insert field newVal o
  case val of
    Object o -> Object <$> foldM updateOne o updates
    _ -> throwError (TypeMismatch "object")
eval mn env (CoreFn.Case _ args alts) = do
  vals <- traverse (eval mn env) args
  result <- runMaybeT (asum (map (match vals) alts))
  case result of
    Nothing -> throwError InexhaustivePatternMatch
    Just (newEnv, matchedExpr) -> eval mn (newEnv <> env) matchedExpr
eval mn _ (CoreFn.Constructor _ _tyName ctor fields) = 
    pure $ go fields []
  where
    go [] applied = Constructor (Qualified (Just mn) ctor) (reverse applied)
    go (_ : tl) applied = Closure \arg -> pure (go tl (arg : applied))

match :: Monad m
      => [Value m]
      -> CoreFn.CaseAlternative ()
      -> MaybeT (EvalT m) (Env m, CoreFn.Expr ())
match vals (CoreFn.CaseAlternative binders expr) 
  | length vals == length binders = do
    newEnv <- fold <$> zipWithM matchOne vals binders
    case expr of
      Left _guards -> throwError (NotSupported "guards")
      Right e -> pure (newEnv, e)
  | otherwise = throwError (InvalidNumberOfArguments (length vals) (length binders))

matchOne 
  :: Monad m
  => Value m
  -> CoreFn.Binder ()
  -> MaybeT (EvalT m) (Env m)
matchOne _ (CoreFn.NullBinder _) = pure mempty
matchOne val (CoreFn.LiteralBinder _ lit) = matchLit val lit
matchOne val (CoreFn.VarBinder _ ident) = do
  pure (Map.singleton (Qualified Nothing ident) val)
matchOne val (CoreFn.NamedBinder _ ident b) = do
  env <- matchOne val b
  pure (Map.insert (Qualified Nothing ident) val env)
matchOne (Constructor ctor vals) (CoreFn.ConstructorBinder _ _tyName ctor' bs) 
  | ctor == ctor'
  = if length vals == length bs 
      then fold <$> zipWithM matchOne vals bs
      else throwError UnsaturatedConstructorApplication
matchOne _ _ = mzero

matchLit
  :: forall m
   . Monad m
  => Value m
  -> CoreFn.Literal (CoreFn.Binder ())
  -> MaybeT (EvalT m) (Env m)
matchLit (Number n) (CoreFn.NumericLiteral (Left i)) 
  | fromIntegral i == n = pure mempty
matchLit (Number n) (CoreFn.NumericLiteral (Right d))
  | realToFrac d == n = pure mempty
matchLit (String s) (CoreFn.StringLiteral pss) = do
  s' <- lift (evalPSString pss)
  guard (s == s')
  pure mempty
matchLit (String s) (CoreFn.CharLiteral chr)
  | s == Text.singleton chr = pure mempty
matchLit (Bool b) (CoreFn.BooleanLiteral b')
  | b == b' = pure mempty
matchLit (Array xs) (CoreFn.ArrayLiteral bs)
  | length xs == length bs
  = fold <$> zipWithM matchOne (Vector.toList xs) bs
matchLit (Object o) (CoreFn.ObjectLiteral bs) = do
  let evalField (pss, b) = do
        t <- lift (evalPSString pss)
        pure (t, (t, b))
  vals <- HashMap.fromList <$> traverse evalField bs
  let matchField :: These (Value m) (Text, CoreFn.Binder ()) -> MaybeT (EvalT m) (Env m)
      matchField This{} = pure mempty
      matchField (That (pss, _)) = throwError (FieldNotFound pss)
      matchField (These val (_, b)) = matchOne val b
  fold <$> sequence (Align.alignWith matchField o vals)
matchLit _ _ = mzero

evalLit :: Monad m => Names.ModuleName -> Env m -> CoreFn.Literal (CoreFn.Expr ()) -> EvalT m (Value m)
evalLit _ _ (CoreFn.NumericLiteral (Left int)) =
  pure $ Number (fromIntegral int)
evalLit _ _ (CoreFn.NumericLiteral (Right dbl)) =
  pure $ Number (realToFrac dbl)
evalLit _ _ (CoreFn.StringLiteral str) =
  String <$> evalPSString str
evalLit _ _ (CoreFn.CharLiteral chr) =
  pure $ String (Text.singleton chr)
evalLit _ _ (CoreFn.BooleanLiteral b) =
  pure $ Bool b
evalLit mn env (CoreFn.ArrayLiteral xs) = do
  vs <- traverse (eval mn env) xs
  pure $ Array (Vector.fromList vs)
evalLit mn env (CoreFn.ObjectLiteral xs) = do
  let evalField (pss, e) = do
        field <- evalPSString pss
        val <- eval mn env e
        pure (field, val)
  Object . HashMap.fromList <$> traverse evalField xs

bind 
  :: forall m
   . Monad m
  => Names.ModuleName
  -> Maybe Names.ModuleName
  -> Env m
  -> [CoreFn.Bind ()] 
  -> EvalT m (Env m)
bind mn scope = foldM go where
  go :: Env m -> CoreFn.Bind () -> EvalT m (Env m)
  go env (CoreFn.NonRec _ name e) = do
    val <- eval mn env e
    pure $ Map.insert (Qualified scope name) val env
  go _ (CoreFn.Rec _) = 
    throwError (NotSupported "recursive bindings")

-- | Apply a value which represents an unevaluated closure to an argument.
apply
  :: Monad m
  => Value m
  -> Value m
  -> EvalT m (Value m)
apply (Closure f) arg = f arg
apply _ _ = throwError (TypeMismatch "closure")
  
class Monad m => ToValue m a where
  toValue :: a -> Value m
  
  default toValue :: (G.Generic a, GToObject m (G.Rep a)) => a -> Value m
  toValue = Object . gToObject . G.from
  
instance Monad m => ToValue m (Value m) where
  toValue = id
  
instance Monad m => ToValue m Integer where
  toValue = Number . fromIntegral
  
instance Monad m => ToValue m Scientific where
  toValue = Number
  
instance Monad m => ToValue m Text where
  toValue = String
  
instance Monad m => ToValue m Bool where
  toValue = Bool

class ToValueRHS m a where
  toValueRHS :: a -> EvalT m (Value m)
  
instance (Monad m, FromValue m a, ToValueRHS m b) => ToValueRHS m (a -> b) where
  toValueRHS f = pure (Closure (\v -> toValueRHS . f =<< fromValue v))
   
instance (ToValue m a, n ~ m) => ToValueRHS m (EvalT n a) where
  toValueRHS = fmap toValue

instance (Monad m, FromValue m a, ToValueRHS m b) => ToValue m (a -> b) where
  toValue f = Closure (\v -> toValueRHS . f =<< fromValue v)

instance ToValue m a => ToValue m (Vector a) where
  toValue = Array . fmap toValue
  
class Monad m => FromValue m a where
  fromValue :: Value m -> EvalT m a
  
  default fromValue :: (G.Generic a, GFromObject m (G.Rep a)) => Value m -> EvalT m a
  fromValue = \case
    Object o -> G.to <$> gFromObject o
    _ -> throwError (TypeMismatch "object")
  
instance Monad m => FromValue m (Value m) where
  fromValue = pure
  
instance Monad m => FromValue m Text where
  fromValue = \case
    String s -> pure s
    _ -> throwError (TypeMismatch "string")
  
instance Monad m => FromValue m Integer where
  fromValue = \case
    Number s
      | Right i <- floatingOrInteger @Double s -> pure i
    _ -> throwError (TypeMismatch "integer")
  
instance Monad m => FromValue m Scientific where
  fromValue = \case
    Number s -> pure s
    _ -> throwError (TypeMismatch "number")
  
instance Monad m => FromValue m Bool where
  fromValue = \case
    Bool b -> pure b
    _ -> throwError (TypeMismatch "boolean")
  
instance FromValue m a => FromValue m (Vector a) where
  fromValue = \case
    Array xs -> traverse fromValue xs
    _ -> throwError (TypeMismatch "array")
  
class FromValueRHS m a where
  fromValueRHS :: EvalT m (Value m) -> a
  
instance (Monad m, ToValue m a, FromValueRHS m b) => FromValueRHS m (a -> b) where
  fromValueRHS mv a = fromValueRHS do
    v <- mv
    fromValueRHS (apply v (toValue a))
   
instance (FromValue m a, n ~ m) => FromValueRHS m (EvalT n a) where
  fromValueRHS = (>>= fromValue)
  
instance (Monad m, FromValueRHS m b, ToValue m a) => FromValue m (a -> b) where
  fromValue f = pure $ \a -> fromValueRHS (apply f (toValue a))
       
class GToObject m f where
  gToObject :: f x -> HashMap Text (Value m)
  
instance GToObject m f => GToObject m (G.M1 G.D t f) where
  gToObject = gToObject . G.unM1
  
instance GToObject m f => GToObject m (G.M1 G.C t f) where
  gToObject = gToObject . G.unM1
  
instance (GToObject m f, GToObject m g) => GToObject m (f G.:*: g) where
  gToObject (f G.:*: g) = gToObject f <> gToObject g
    
instance 
    forall m field u s l r a
     . ( KnownSymbol field
       , ToValue m a
       ) 
    => GToObject m 
         (G.M1 
           G.S
           ('G.MetaSel 
             ('Just field) 
             u s l) 
            (G.K1 r a)) 
  where
    gToObject (G.M1 (G.K1 a)) = do
      let field = Text.pack (symbolVal @field (Proxy :: Proxy field))
       in HashMap.singleton field (toValue a)
  
class GFromObject m f where
  gFromObject :: HashMap Text (Value m) -> EvalT m (f x)
  
instance (Functor m, GFromObject m f) => GFromObject m (G.M1 G.D t f) where
  gFromObject = fmap G.M1 . gFromObject
  
instance (Functor m, GFromObject m f) => GFromObject m (G.M1 G.C t f) where
  gFromObject = fmap G.M1 . gFromObject

instance 
    forall m field u s l r a
     . ( KnownSymbol field
       , FromValue m a
       ) 
    => GFromObject m 
         (G.M1 
           G.S
           ('G.MetaSel 
             ('Just field) 
             u s l) 
            (G.K1 r a)) 
  where
    gFromObject o = do
      let field = Text.pack (symbolVal @field (Proxy :: Proxy field))
      case HashMap.lookup field o of
        Nothing -> throwError (FieldNotFound field)
        Just v -> G.M1 . G.K1 <$> fromValue v
  
instance (Monad m, GFromObject m f, GFromObject m g) => GFromObject m (f G.:*: g) where
  gFromObject o = (G.:*:) <$> gFromObject o <*> gFromObject o