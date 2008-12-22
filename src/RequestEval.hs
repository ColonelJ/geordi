module RequestEval (evaluator) where

import qualified Data.Set as Set
import qualified EvalCxx
import qualified Editing.Parse
import qualified Editing.Diff
import qualified Editing.Execute
import qualified Cxx.Parse
import qualified Cxx.Operations
import qualified Cxx.Show
import Cxx.Show
import Control.Monad.Error ()
import qualified Data.List as List
import Data.Char (isPrint)
import Data.Maybe (listToMaybe)
import Data.Either (lefts)
import Parsers ((<|>), eof, optParser, option, spaces, getInput, kwd, kwds, Parser, run_parser, ParseResult(..), optional, parseOrFail)
import Util ((.), (<<), (.||.), commas_and, capitalize, orElse, length_ge, replace, maybe_ne, unne, show_long_opt)
import Request (Context(..), EvalOpt(..), Response(..), EditableRequest(..), EditableRequestKind(..), EphemeralOpt(..))
import Prelude hiding (catch, (.))

no_break_space :: Char
no_break_space = '\x00A0'

diff :: EditableRequest -> EditableRequest -> String
diff (EditableRequest MakeType y) (EditableRequest MakeType x) = pretty $ show . Editing.Diff.diff x y
diff (EditableRequest Precedence y) (EditableRequest Precedence x) = pretty $ show . Editing.Diff.diff x y
diff (EditableRequest (Evaluate flags) y) (EditableRequest (Evaluate flags') x) =
  pretty $ f "removed" flags' flags ++ f "added" flags flags' ++ show . Editing.Diff.diff x y
    where f n fl fl' = maybe [] (\l -> [n ++ " " ++ concat (List.intersperse " and " $ map show_long_opt $ unne l)]) (maybe_ne $ Set.elems $ (Set.\\) fl fl')
diff _ _ = "Requests differ in kind."

pretty :: [String] -> String -- Todo: This is awkward.
pretty [] = "Requests are identical."
pretty l = capitalize (commas_and l) ++ "."

evaluator :: IO (String -> Context -> IO Response)
evaluator = do
  (ev, compile_cfg) <- EvalCxx.evaluator
  let
    evf :: EvalCxx.Request -> IO String
    evf r = filter (isPrint .||. (== '\n')) . show . ev r
    -- Filtering using isPrint works properly because (1) the EvalCxx evaluator returns proper Unicode Strings, not mere byte blobs; and (2) to print filtered strings we will use System.IO.UTF8's hPutStrLn which properly UTF-8-encodes the filtered String.
    -- Possible problem: terminals which have not been (properly) UTF-8 configured might interpret bytes that are part of UTF-8 encoded characters as control characters.
    prel = "#include \"prelude.hpp\"\n"
    respond :: EditableRequest -> IO String
    respond (EditableRequest MakeType d) = return $ either ("error: " ++) show_simple $ Cxx.Parse.makeType d
    respond (EditableRequest Precedence t) = return $ either ("error: " ++) id $ Cxx.Parse.precedence t
    respond (EditableRequest (Evaluate opts) code) =
      case parseOrFail (Cxx.Parse.code << eof) code "request" of
        Right sc -> do
          evf $ EvalCxx.Request (prel ++ (if Set.member Terse opts then "#include \"terse.hpp\"\n" else "") ++ show (Cxx.Operations.expand $ Cxx.Operations.shortcut_syntaxes $ Cxx.Operations.line_breaks sc)) (not $ Set.member CompileOnly opts) (Set.member NoWarn opts)
        Left x -> return $ "error: " ++ x
    error_response s = return $ return $ Response Nothing $ "error: " ++ s
    respond_and_remember er = return $ Response (Just er) . respond er

  return $ \r (Context prevs) -> do
  let
    p :: Parser Char (IO Response)
    p =
      do
        kwd "show"; eof
        return $ return $ Response Nothing $ show . listToMaybe prevs `orElse` "<none>"
      <|> do
        kwds ["--precedence", "precedence"]
        respond_and_remember . EditableRequest Precedence =<< getInput
      <|> do
        kwds ["--make-type", "make type"]
        respond_and_remember . EditableRequest MakeType =<< getInput
      <|> do
        kwds ["--help", "-h", "help"]
        return $ Response Nothing . evf (EvalCxx.Request (prel ++ "int main() { cout << help; }") True False)
      <|> do
        kwds ["--version", "-v", "version"]
        return $ Response Nothing . evf (EvalCxx.Request (prel ++ "int main() { cout << \"g++ (GCC) \" << __VERSION__; }") True False)
      <|> do
        kwd "--show-compile-flags"
        return $ return $ Response Nothing $ unwords $ EvalCxx.compileFlags compile_cfg
      <|> do
        kwds ["diff", "diffs", "differences", "change", "changes"]; eof
        case prevs of
          x : y : _ -> return $ return $ Response Nothing $ diff x y
          _ -> error_response "I have not yet seen two comparable requests."
      <|> do
        optional (kwd "try"); kwd "again"; eof
        case prevs of
          [] -> error_response "There is no repeatable request."
          x : _ -> return $ Response Nothing . respond x
      <|> do
        cs' <- Editing.Parse.commandsP; eof
        case cs' of
          Left e -> error_response e
          Right cs -> case prevs of
            [] -> error_response "There is no previous editable request."
            prev : _ -> case Editing.Execute.execute cs prev of
              Left e -> error_response e
              Right (EditableRequest _ edited_body) | length_ge 1000 edited_body ->
                error_response "Request would become too large."
              Right edited -> respond_and_remember edited
      <|> do
        mopts <- option (return []) optParser; spaces
        (\z -> either error_response z mopts) $ \opts -> do
        let evalopts = Set.fromList $ lefts opts
        if Right Resume `elem` opts
          then case prevs of
            [] -> fail "There is no previous resumable request."
            EditableRequest (Evaluate oldopts) oldcodeblob : _ -> case run_parser (Cxx.Parse.code << eof) oldcodeblob of
              ParseSuccess oldcode _ _ _ -> do
                code <- Cxx.Parse.code; eof
                respond_and_remember $ EditableRequest (Evaluate $ Set.union evalopts oldopts) $ show $ Cxx.Operations.blob $ Cxx.Operations.resume (Cxx.Operations.shortcut_syntaxes oldcode) (Cxx.Operations.shortcut_syntaxes code)
              ParseFailure _ _ -> error_response "Previous request too malformed to resume."
            _ -> error_response "Last (editable) request was not resumable."
          else respond_and_remember =<< EditableRequest (Evaluate evalopts) . getInput
  either (return . Response Nothing) id $ parseOrFail p (replace no_break_space ' ' r) "request"