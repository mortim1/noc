module Interactive.REPL where

----------------Modules ------------------------------------------ù

import Control.Monad.Except
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.RWS
import Control.Monad.State (runStateT)
import Data.Maybe (fromMaybe)
import Interactive.Commands
import Language.Noc.PrettyPrinter (displayStack)
import Language.Noc.Runtime.Prelude (prelude)
import Language.Noc.Runtime.Eval
import Language.Noc.Runtime.Internal
import Language.Noc.Syntax.AST
import Language.Noc.Syntax.Lexer
import System.Console.Haskeline
import System.Directory (XdgDirectory (..), getXdgDirectory)
import System.IO (hFlush, stdout)
import Text.Parsec (ParseError, eof, parse, (<|>))
import Text.Parsec.String (Parser)
import Data.Map (Map,toList)
import Data.Text (Text,pack)

----------------------- REPL Parser -------------------------------

data REPLInput = DeclInput (Map Text Expr) | ExprInput Expr deriving (Show, Eq)

replFunction :: Parser REPLInput
replFunction = (function <* eof) >>= (pure . DeclInput)

replExpression :: Parser REPLInput
replExpression = (whiteSpace *> stack) >>= (pure . ExprInput)

parseREPL :: String -> Either ParseError REPLInput
parseREPL expr = parse (replFunction <|> replExpression) "" expr

----------------------- REPL Eval -------------------------------

funcREPL :: (Map Text Expr) -> Env -> Either EvalError ((), Env)
funcREPL func env = do
  let func' = toList func
  runExcept $ runStateT (evalFunc func') env

exprREPL :: Expr -> Stack -> Env -> IO (Either EvalError ((), Stack, ()))
exprREPL expr stack env = runExceptT $ runRWST (eval expr) (prelude <> env) stack

----------------------- REPL Session -----------------------------
defaultSettings' :: MonadIO m => FilePath -> Settings m
defaultSettings' path =
  Settings
    { complete = completeFilename,
      historyFile = Just path,
      autoAddHistory = True
    }

prompt :: IO [String]
prompt = do
  path <- getXdgDirectory XdgCache ".noc_history"
  input <- runInputT (defaultSettings' path) (getInputLine "noc> ")
  return $ words $ fromMaybe "" input

nocREPL :: Stack -> Env -> IO ()
nocREPL stack env = prompt >>= repl stack env

----------------- REPL Commands  -----------------------------------

run :: String -> [(String, REPLCommands)] -> Stack -> Env -> IO ()
run name funcs stack env = case name `elem` (map fst funcs) of
  True -> do
    let (Just f) = lookup name funcs
    let (REPLCommands _ _ action) = f
    action
  False -> (putStrLn ("Unknown command '" ++ name ++ "' or lack of arguments")) >> (nocREPL stack env)


repl :: Stack -> Env -> [String] -> IO ()
repl stack env [] = nocREPL stack env
repl stack env ((':' : cmd) : args) = run cmd (commands args stack env nocREPL) stack env
repl stack env code = do
  let expression = unwords code
  let parsed = parseREPL expression
  case parsed of
    (Left err) -> (print err) >> nocREPL stack env
    (Right succ) -> case succ of
      ---
      (ExprInput []) -> (putStrLn ("Noc doesn't recognize '" ++ expression ++ "' expression.")) >> nocREPL stack env
      (DeclInput decl) -> case funcREPL decl env of
        ---
        (Left err') -> print err' >> nocREPL stack env
        (Right ((), newenv)) -> nocREPL stack newenv
        ---
      (ExprInput expr) -> do
          eval' <- exprREPL expr stack env
          case eval' of
            ---
            (Left err'') -> print err'' >> nocREPL stack env
            (Right ((), s, ())) -> (putStrLn $ displayStack s) >> (nocREPL s env)