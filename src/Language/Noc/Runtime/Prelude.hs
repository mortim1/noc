{-# LANGUAGE RankNTypes #-}

module Language.Noc.Runtime.Prelude where

import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.RWS
import Control.Monad.State
import qualified Data.Map as M (fromList, keys, lookup)
import qualified Data.Text as T (Text, pack, replace, splitOn, unpack)
import qualified Data.Text.IO as TIO (getLine, readFile)
import Language.Noc.PrettyPrinter
import Language.Noc.Runtime.Internal
import Language.Noc.Runtime.PreludeDoc
import Language.Noc.Syntax.AST
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO
import Text.Read (readMaybe)
import Control.Monad.IO.Class (liftIO)

----------------------------------------------------

prelude :: Env
prelude =
  M.fromList
    [ -- Stack-shuffler
      (T.pack "dup", Constant $ (docDup, PrimVal builtinDup)),
      (T.pack "pop", Constant $ (docPop, PrimVal builtinPop)),
      (T.pack "zap", Constant $ (docZap, PrimVal builtinZap)),
      (T.pack "cat", Constant $ (docCat, PrimVal builtinCat)),
      (T.pack "rotNM", Constant $ (docRotNM, PrimVal builtinRotNM)),
      -- Arithmetic operators
      (T.pack "+", Constant $ (docOp "+", PrimVal $ builtinOp (+))),
      (T.pack "-", Constant $ (docOp "-", PrimVal $ builtinOp (-))),
      (T.pack "*", Constant $ (docOp "*", PrimVal $ builtinOp (*))),
      (T.pack "/", Constant $ (docDiv, PrimVal $ builtinDiv)),
      -- I/O
      (T.pack "print", Constant $ (docPrint, PrimVal builtinPrint)),
      (T.pack "putstr", Constant $ (docPutStr, PrimVal builtinPutStr)),
      (T.pack "ask", Constant $ (docAsk, PrimVal builtinAsk)),
      (T.pack "args", Constant $ (docArgs, PrimVal builtinArgs)),
      -- Fs
      (T.pack "read", Constant $ (docReadFile, PrimVal builtinReadFile)),
      (T.pack "write", Constant $ (docWrite, PrimVal builtinWrite)),
      -- Quote
      (T.pack "unquote", Constant $ (docUnquote, PrimVal builtinUnquote)),
      (T.pack "pushr", Constant $ (docPushr, PrimVal builtinPushr)),
      (T.pack "popr", Constant $ (docPopr, PrimVal builtinPopr)),
      -- Misc
      (T.pack "id", Constant $ (docId, PrimVal builtinId)),
      (T.pack "str", Constant $ (docStr, PrimVal builtinStr)),
      (T.pack "int", Constant $ (docInt, PrimVal builtinInt)),
      (T.pack "float", Constant $ (docFloat, PrimVal builtinFloat)),
      (T.pack "exit", Constant $ (docExit, PrimVal builtinExit)),
      (T.pack "format", Constant $ (docFormat, PrimVal builtinFormat)),
      (T.pack "help", Constant $ (docHelp, PrimVal builtinHelp)),
      (T.pack "bool", Constant $ (docBool, PrimVal builtinBool)),
      (T.pack "case", Constant $ (docCase, PrimVal builtinCase))
    ]

----------------------------------------------------

builtinOp :: (forall a. Num a => a -> a -> a) -> Eval ()
builtinOp operator = do
  v1 <- pop
  v2 <- pop
  case (v1, v2) of
    ((FloatVal v1'), (FloatVal v2')) -> push $ FloatVal $ operator v2' v1'
    ((IntVal v1'), (IntVal v2')) -> push $ IntVal $ operator v2' v1'
    ((FloatVal v1'), (IntVal v2')) -> push $ FloatVal $ operator (fromIntegral v2') v1'
    ((IntVal v1'), (FloatVal v2')) -> push $ FloatVal $ operator v2' (fromIntegral v1')
    _ -> throwError $ TypeError "cannot operate with different types."

----------------------------------------------------

builtinDiv :: Eval ()
builtinDiv = do
  v1 <- pop
  v2 <- pop
  case (v1, v2) of
    ((FloatVal v1'), (FloatVal v2')) -> operateDiv v1' v2'
    ((IntVal v1'), (IntVal v2')) -> operateDiv (fromIntegral v1') (fromIntegral v2')
    ((FloatVal v1'), (IntVal v2')) -> operateDiv v1' (fromIntegral v2')
    ((IntVal v1'), (FloatVal v2')) -> operateDiv (fromIntegral v1') v2'
    _ -> throwError $ TypeError "cannot operate with different types."
  where
    operateDiv v1 v2 = case v1 of
      0 -> throwError $ ZeroDivisionError $ "cannot divide by 0."
      _ -> push $ FloatVal $ (/) v2 v1

----------------------------------------------------

builtinDup :: Eval ()
builtinDup = do
  v1 <- pop
  push v1 >> push v1

----------------------------------------------------

builtinPop :: Eval ()
builtinPop = do
  v1 <- pop
  return ()

----------------------------------------------------

builtinZap :: Eval ()
builtinZap = put [] >> return ()

----------------------------------------------------

builtinCat :: Eval ()
builtinCat = do
  v1 <- pop
  v2 <- pop
  case (v1, v2) of
    ((QuoteVal a), (QuoteVal b)) -> push $ (QuoteVal $ b ++ a)
    ((StringVal a), (StringVal b)) -> push $ (StringVal $ b <> a)
    _ -> throwError $ TypeError "cannot cat with different types or concat functions,floats."

----------------------------------------------------

builtinRotNM :: Eval ()
builtinRotNM = do
  m <- pop
  n <- pop
  stack <- get
  case stack of
    [] -> throwError $ EmptyStackError "no or few elements in the stack."
    _ -> case m of
      (IntVal m') -> case n of
        (IntVal n') -> case n' <= 0 of
          True -> case n' == 0 of
            True -> return ()
            False -> throwError $ ValueError "cannot rotate with a negative number in first parameter."
          False -> do
            let original = take (length stack - (fromIntegral n')) stack
            let rot = drop (length stack - (fromIntegral n')) stack
            let result f x = last $ take (fromIntegral $ x + 1) (iterate f rot)
            case m' < 0 of
              True -> do
                let rotate l = tail l ++ [head l]
                put $ original <> (result rotate (abs m'))
              False -> do
                let rotate l = [last l] ++ init l
                put $ original <> (result rotate m')
        _ -> throwError $ TypeError "the first parameter must be an integer."
      _ -> throwError $ TypeError "the second parameter must be an integer."

----------------------------------------------------

builtinUnquote :: Eval ()
builtinUnquote = do
  v1 <- pop
  case v1 of
    ((QuoteVal x)) -> evalExpr x
    _ -> throwError $ TypeError "can only unquote with a quotation."

----------------------------------------------------

builtinPopr :: Eval ()
builtinPopr = do
  env <- ask
  v1 <- pop
  case v1 of
    ((QuoteVal x)) -> case reverse x of
      [] -> return ()
      ((WordAtom y) : ys) -> (push $ QuoteVal $ reverse ys) >> (evalWord y env)
      (y : ys) -> (push $ QuoteVal $ reverse ys) >> (push $ readValue y)
    _ -> throwError $ TypeError "can only popr with a quotation."

----------------------------------------------------

builtinPrint :: Eval ()
builtinPrint = do
  v <- pop
  case v of
    (StringVal x) -> (liftIO $ print x) >> return ()
    (FloatVal x) -> (liftIO $ print x) >> return ()
    (IntVal x) -> (liftIO $ print x) >> return ()
    (BoolVal x) -> (liftIO $ print x) >> return ()
    (QuoteVal x) -> (liftIO $ putStrLn $ displayQuote x)
    _ -> throwError $ TypeError "can only print with strings,floats,integers,bool."

----------------------------------------------------

builtinPutStr :: Eval ()
builtinPutStr = do
  v <- pop
  case v of
    (StringVal x) -> (liftIO $ putStr $ T.unpack $ x) >> return ()
    _ -> throwError $ TypeError "can only putstr with strings."

----------------------------------------------------

builtinReadFile :: Eval ()
builtinReadFile = do
  path <- pop
  case path of
    (StringVal x) -> do
      content <- liftIO (try $ TIO.readFile (T.unpack x) :: IO (Either SomeException T.Text))
      case content of
        (Left err) -> liftIO $ print "the file does not exist (no such file or directory)"
        (Right succ) -> push $ StringVal succ
    _ -> throwError $ TypeError "the parameter is not string."

----------------------------------------------------

builtinAsk :: Eval ()
builtinAsk = do
  msg <- pop
  case msg of
    (StringVal x) -> do
      liftIO $ putStr $ T.unpack x
      liftIO $ hFlush stdout
      inp <- liftIO $ TIO.getLine
      push $ StringVal inp
    _ -> throwError $ TypeError "the parameter is not string."

----------------------------------------------------

builtinArgs :: Eval ()
builtinArgs = do
  args <- liftIO getArgs
  case args of
    [] -> push $ QuoteVal []
    (_ : y : args) -> case y of
      "--" -> push $ QuoteVal (map StringAtom args)
      _ -> push $ QuoteVal (map StringAtom (y : args))
    _ -> push $ QuoteVal (map StringAtom args)

----------------------------------------------------

builtinPushr :: Eval ()
builtinPushr = do
  v <- pop
  l <- pop
  case l of
    (QuoteVal l') -> push $ QuoteVal (l' <> [readAtom v])
    _ -> throwError $ TypeError "can only pushr with a quotation."

----------------------------------------------------

builtinWrite :: Eval ()
builtinWrite = do
  content <- pop
  path <- pop
  case path of
    (StringVal p) -> case content of
      (StringVal c) -> liftIO $ writeFile (T.unpack p) (T.unpack c)
      _ -> throwError $ TypeError "the first parameter is not string."
    _ -> throwError $ TypeError "the second parameter is not string."

----------------------------------------------------

builtinId :: Eval ()
builtinId = do
  v <- pop
  push v

----------------------------------------------------

builtinStr :: Eval ()
builtinStr = do
  v <- pop
  case v of
    (StringVal x) -> push $ StringVal x
    (FloatVal x) -> push $ StringVal $ T.pack $ show x
    (IntVal x) -> push $ StringVal $ T.pack $ show x
    (BoolVal x) -> push $ StringVal $ T.pack $ show x
    (QuoteVal x) -> push $ StringVal $ T.pack $ displayQuote x
    _ -> throwError $ TypeError "can only str with str,float,int,bool"

----------------------------------------------------

builtinInt :: Eval ()
builtinInt = do
  v <- pop
  case v of
    (IntVal x) -> push $ IntVal x
    (StringVal x) -> case readMaybe (T.unpack x) :: Maybe Integer of
      (Just v) -> push $ IntVal v
      Nothing -> throwError $ ValueError "the value is not a integer."
    _ -> throwError $ TypeError "can only int with int,str"

----------------------------------------------------

builtinFloat :: Eval ()
builtinFloat = do
  v <- pop
  case v of
    (IntVal x) -> push $ FloatVal $ fromIntegral x
    (FloatVal x) -> push $ FloatVal x
    (StringVal x) -> case readMaybe (T.unpack x) :: Maybe Double of
      (Just v) -> push $ FloatVal v
      Nothing -> throwError $ ValueError "the value is not a integer."
    _ -> throwError $ TypeError "can only float with int,float,str"

----------------------------------------------------

builtinExit :: Eval ()
builtinExit = do
  returncode <- pop
  case returncode of
    (IntVal x) -> case x of
      0 -> liftIO exitSuccess
      n -> liftIO $ (putStrLn $ "*** Exception: ExitFailure " <> show n) >> (exitWith $ ExitFailure $ fromIntegral n)
    _ -> throwError $ TypeError "the exit parameter must be an integer parameter."

----------------------------------------------------

format' :: [T.Text] -> Expr -> [T.Text] -> Either EvalError [T.Text]
format' [] [] res = Right res
format' [] _ res = Right res
format' (x : xs) (y : ys) res = case isBrace x of
  True -> case y of
    (StringAtom a) -> format' xs ys (T.replace (T.pack "{}") (T.pack a) x : res)
    (IntAtom a) -> format' xs ys (T.replace (T.pack "{}") (T.pack $ show a) x : res)
    (FloatAtom a) -> format' xs ys (T.replace (T.pack "{}") (T.pack $ show a) x : res)
    (BoolAtom a) -> format' xs ys (T.replace (T.pack "{}") (T.pack $ show a) x : res)
    (QuoteAtom a) -> format' xs ys (T.replace (T.pack "{}") (T.pack $ displayQuote a) x : res)
    _ -> Left $ TypeError "format: cannot format with this type."
  False -> format' xs (y : ys) (x : res)
format' (x : xs) [] res = case isBrace x of
  True -> Left $ ValueError "format: too many braces."
  False -> format' xs [] (x : res)

builtinFormat :: Eval ()
builtinFormat = do
  quote <- pop
  str <- pop
  case str of
    (StringVal s) -> case quote of
      (QuoteVal l) -> do
        stack <- get
        builtinZap
        evalExpr l
        putAllInQuote []
        newstack <- get
        put $ stack <> newstack
        v <- pop
        let (QuoteVal val) = v
        let toFormat = format' (T.splitOn (T.pack " ") s) val []
        case toFormat of
          (Left err) -> throwError $ err
          (Right succ) -> push $ StringVal $ T.pack $ initSafe $ T.unpack $ foldl (\acc x -> (x <> T.pack " ") <> acc) (T.pack "") succ
      _ -> throwError $ TypeError "cannot format with a wrong parameter (the second parameter is a quote)."
    _ -> throwError $ TypeError "cannot format with a wrong parameter (the first parameter is a string)."

----------------------------------------------------

builtinHelp :: Eval ()
builtinHelp = do
  env <- ask
  quote <- pop
  case quote of
    (QuoteVal n) -> case n of
      [WordAtom n'] -> case M.lookup (T.pack n') env of
        (Just (Constant (d, _))) -> liftIO $ liftIO $ putStrLn $ "docstring for '" <> n' <> "' function:\n------------\n" <> d
        (Just (Function (d, _))) -> case d of
          (Just d') -> liftIO $ putStrLn $ "docstring for '" <> n' <> "' function:\n------------\n" <> d'
          Nothing -> liftIO $ putStrLn $ "no documentation entry for '" <> n' <> "' function."
        Nothing -> throwError $ NameError $ "the '" <> n' <> "' function does not exists."
      _ -> throwError $ ValueError $ "bad expression in the quote (required: function)."
    _ -> throwError $ TypeError "cannot help without a quote parameter."

----------------------------------------------------

builtinBool :: Eval ()
builtinBool = do
  v <- pop
  case v of
    (IntVal 0) -> push $ BoolVal False
    _ -> push $ BoolVal True

----------------------------------------------------

isPattern :: Atom -> Bool
isPattern x = case x of
  (QuoteAtom [QuoteAtom _, QuoteAtom _]) -> True
  (QuoteAtom _) -> True
  _ -> False 

eqValue :: Value -> Value -> Bool
eqValue a b = 
  case (a,b) of
  (QuoteVal x, QuoteVal y) -> x == y
  (FloatVal x, FloatVal y) -> x == y
  (IntVal x, IntVal y) -> x == y
  (StringVal x, StringVal y) ->  x == y
  (BoolVal x, BoolVal y) -> x == y
  _ -> False

runCase :: Value -> Expr -> Eval ()
runCase _ [] = throwError $ EmptyStackError "no pattern matches."
runCase c (p:ps) = do
  case p of
    (QuoteAtom [QuoteAtom [WordAtom "_"], QuoteAtom expr]) -> evalExpr expr
    (QuoteAtom [QuoteAtom p', QuoteAtom expr]) -> do
      evalExpr p'
      p'' <- pop
      case eqValue c p'' of
        True -> evalExpr expr
        False -> runCase c ps
    _ -> throwError $ ValueError "cannot case with bad pattern(s)."

builtinCase :: Eval ()
builtinCase = do
  patterns <- pop
  tocase <- pop
  case tocase of
    (QuoteVal c) -> case patterns of
      (QuoteVal pat) -> do
        evalExpr c
        case' <- pop
        --- 
        case all isPattern pat of
          True -> runCase case' pat
          False -> throwError $ ValueError "cannot case with bad pattern(s)."
      _ ->  throwError $ TypeError "cannot case with a wrong type. (the second parameter must be a quote)."
    _ -> throwError $ TypeError "cannot case with a wrong type. (the first parameter must be a quote)."