{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- | A tiny standard library.
module Dovetail.Prelude where
  
import Control.Monad.Fix (MonadFix)
import Control.Monad.Error.Class (catchError, throwError)
import Data.Char (chr, ord)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Dovetail.Evaluate (ToValue, ToValueRHS, toValue)
import Dovetail.FFI (FFI(..), ForeignImport(..))
import Dovetail.FFI.Builder (array, boolean, char, int, string, number, (~>))
import Dovetail.FFI.Builder qualified as FFI
import Dovetail.FFI.Internal (forAll, function)
import Dovetail.Types
import Language.PureScript qualified as P
import Language.PureScript.Constants.Prim (pattern Partial)

stdlib :: MonadFix m => [FFI m]
stdlib = 
  [ prelude
  , preludeArray
  , preludeString
  , preludeChar
  , preludeNumber
  , preludeInt
  , preludeBoolean
  , preludeDebug
  , preludePartial
  ]

prelude :: MonadFix m => FFI m
prelude = FFI.evalFFIBuilder (P.ModuleName "Prelude") do
  FFI.foreignImport (P.Ident "identity") 
    (\a -> a ~> a)
    pure
  FFI.foreignImport (P.Ident "flip") 
    (\a b c -> (a ~> b ~> c) ~> b ~> a ~> c)
    flip
    
preludeArray :: MonadFix m => FFI m
preludeArray = FFI.evalFFIBuilder (P.ModuleName "Prelude.Array") do
  FFI.foreignImport (P.Ident "map") 
    (\a b -> (a ~> b) ~> array a ~> array b)
    traverse
  FFI.foreignImport (P.Ident "filter") 
    (\a -> (a ~> boolean) ~> array a ~> array a)
    Vector.filterM
  FFI.foreignImport (P.Ident "foldl") 
    (\a b -> (b ~> a ~> b) ~> b ~> array a ~> b)
    Vector.foldM
  FFI.foreignImport (P.Ident "zipWith") 
    (\a b c -> (a ~> b ~> c) ~> array a ~> array b ~> array c)
    Vector.zipWithM
  FFI.foreignImport (P.Ident "append")
    (\a -> array a ~> array a ~> array a)
    (\xs ys -> pure (xs <> ys))
  
preludeString :: MonadFix m => FFI m
preludeString = FFI.evalFFIBuilder (P.ModuleName "Prelude.String") do
  eqOps string
  ordOps string
  
  FFI.foreignImport (P.Ident "append")
    (string ~> string ~> string)
    (\xs ys -> pure (xs <> ys))
  FFI.foreignImport (P.Ident "singleton")
    (char ~> string)
    (pure . Text.singleton)
    
preludeChar :: MonadFix m => FFI m
preludeChar = FFI.evalFFIBuilder (P.ModuleName "Prelude.Char") do
  eqOps char
  ordOps string
  
  FFI.foreignImport (P.Ident "chr")
    (int ~> char)
    (pure . chr . fromIntegral)
  FFI.foreignImport (P.Ident "ord")
    (char ~> int)
    (pure . fromIntegral . ord)
    
preludeNumber :: MonadFix m => FFI m
preludeNumber = FFI.evalFFIBuilder (P.ModuleName "Prelude.Number") do
  numOps number
  ordOps number

  FFI.foreignImport (P.Ident "div")
    (number ~> number ~> number)
    (\x y -> pure (x / y))

  FFI.foreignImport (P.Ident "floor")
    (number ~> int)
    (pure . floor)
  FFI.foreignImport (P.Ident "ceiling")
    (number ~> int)
    (pure . ceiling)
  FFI.foreignImport (P.Ident "round")
    (number ~> int)
    (pure . round)
  FFI.foreignImport (P.Ident "truncate")
    (number ~> int)
    (pure . truncate)
  
preludeInt :: MonadFix m => FFI m
preludeInt = FFI.evalFFIBuilder (P.ModuleName "Prelude.Int") do
  eqOps int
  numOps int
  ordOps int

  FFI.foreignImport (P.Ident "div")
    (int ~> int ~> int)
    (\x y -> pure (x `div` y))

  FFI.foreignImport (P.Ident "toNumber")
    (int ~> number)
    (pure . fromIntegral)
  
preludeBoolean :: MonadFix m => FFI m
preludeBoolean = FFI.evalFFIBuilder (P.ModuleName "Prelude.Boolean") do
  eqOps boolean
  ordOps string
  
  FFI.foreignImport (P.Ident "and")
    (boolean ~> boolean ~> boolean)
    (\x y -> pure (x && y))
  FFI.foreignImport (P.Ident "or")
    (boolean ~> boolean ~> boolean)
    (\x y -> pure (x || y))
  FFI.foreignImport (P.Ident "not")
    (boolean ~> boolean)
    (pure . not)
    
preludeDebug :: MonadFix m => FFI m
preludeDebug = 
  FFI.evalFFIBuilder (P.ModuleName "Prelude.Debug") do
    FFI.foreignImport (P.Ident "show")
      (\a -> a ~> string)
      (pure . renderValue (RenderValueOptions False Nothing))
    FFI.foreignImport (P.Ident "crash")
      (\a -> string ~> a)
      (throwErrorWithContext . OtherError)
      
preludePartial :: forall m. MonadFix m => FFI m
preludePartial = 
  let partial ty =
        P.ConstrainedType P.nullSourceAnn 
          (P.Constraint P.nullSourceAnn Partial [] [] Nothing) 
          ty
   in FFI
        { ffi_moduleName = P.ModuleName "Prelude.Partial"
        , ffi_values = 
            [ ForeignImport
                { fv_name = P.Ident "unsafePartial"
                , fv_type = 
                    forAll \a -> partial a `function` a
                , fv_value =
                    toValue @m @((Value m -> EvalT m (Value m)) -> EvalT m (Value m)) 
                      \f -> f (Object mempty)
                }
            , ForeignImport
                { fv_name = P.Ident "fromPartial"
                , fv_type = 
                    forAll \a -> 
                      a `function` (partial a `function` a)
                , fv_value =
                    toValue @m @(Value m -> (Value m -> EvalT m (Value m)) -> EvalT m (Value m)) 
                      \def f -> do
                        catchError (f (Object mempty)) \case
                          EvaluationError { errorType = InexhaustivePatternMatch _ } ->
                            pure def
                          err ->
                            throwError err
                }
            ]
        }

eqOps 
  :: (ToValue m a, ToValueRHS m (EvalT m a), Eq a)
  => FFI.FunctionType m a (EvalT m a)
  -> FFI.FFIBuilder m ()
eqOps ty = do
  FFI.foreignImport (P.Ident "eq")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x == y))
  FFI.foreignImport (P.Ident "neq")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x /= y))

numOps 
  :: (ToValue m a, ToValueRHS m (EvalT m a), Num a)
  => FFI.FunctionType m a (EvalT m a)
  -> FFI.FFIBuilder m ()
numOps ty = do
  FFI.foreignImport (P.Ident "add")
    (ty ~> ty ~> ty)
    (\x y -> pure (x + y))
  FFI.foreignImport (P.Ident "sub")
    (ty ~> ty ~> ty)
    (\x y -> pure (x - y))
  FFI.foreignImport (P.Ident "mul")
    (ty ~> ty ~> ty)
    (\x y -> pure (x * y))
    
ordOps 
  :: (ToValue m a, ToValueRHS m (EvalT m a), Ord a)
  => FFI.FunctionType m a (EvalT m a)
  -> FFI.FFIBuilder m ()
ordOps ty = do
  FFI.foreignImport (P.Ident "min")
    (ty ~> ty ~> ty)
    (\x y -> pure (x `min` y))
  FFI.foreignImport (P.Ident "max")
    (ty ~> ty ~> ty)
    (\x y -> pure (x `max` y))
    
  FFI.foreignImport (P.Ident "lt")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x < y))
  FFI.foreignImport (P.Ident "gt")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x > y))
  FFI.foreignImport (P.Ident "lte")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x <= y))
  FFI.foreignImport (P.Ident "gte")
    (ty ~> ty ~> boolean)
    (\x y -> pure (x >= y))

