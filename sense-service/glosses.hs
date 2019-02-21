import PGF2
import Database.Helda
import SenseSchema
import Data.Char
import Data.List(partition,intercalate)
import Data.Maybe
import Data.Data
import System.Directory
import Control.Monad
import qualified Data.Map as Map

main = do
  ls <- fmap lines $ readFile "WordNet.gf"
  let fundefs = Map.fromListWith (++) (mapMaybe parseSynset ls)

  fn_examples <- fmap (parseExamples . lines) $ readFile "examples.txt"

  ls <- fmap lines $ readFile "embedding.txt"
  let (cs,ws) = parseEmbeddings ls

  let db_name = "semantics.db"
  fileExists <- doesFileExist db_name
  when fileExists (removeFile db_name)
  db <- openDB db_name
  runHelda db ReadWriteMode $ do
    createTable examples
    ex_keys <- fmap (Map.fromListWith (++) . concat) $ forM fn_examples $ \(fns,e) -> do
                 key <- insert examples e
                 return [(fn,[key]) | fn <- fns]

    createTable synsets
    lex_infos <- forM (Map.toList fundefs) $ \(synset,funs) -> do
                   key <- insert synsets synset
                   return [Lexeme fun key ds (fromMaybe [] (Map.lookup fun ex_keys)) | (fun,ds) <- funs]

    createTable lexemes
    mapM_ (insert lexemes) (concat lex_infos)

    createTable coefficients
    insert coefficients cs

    createTable embeddings
    mapM_ (insert embeddings) ws
    
    createTable checked
  closeDB db

parseSynset l =
  case words l of
    ("fun":fn:_) -> case break (=='\t') l of
                      (l1,'\t':l2) -> let (ds,l3) = splitDomains l2
                                          (es,gs) = partition isExample (parseComment l3) 
                                          synset = Synset ((reverse . take 10 . reverse) l1) (merge gs)
                                      in Just (synset, [(fn,ds)])
                      _            -> Nothing
    _            -> Nothing
  where
    splitDomains ('[':cs) = split cs
      where
        trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

        split cs =
          case break (flip elem ",]") cs of
            (x,',':cs) -> let (xs,cs') = split (dropWhile isSpace cs)
                          in (trim x : xs, dropWhile isSpace cs')
            (x,']':cs) -> let x' = trim x
                          in (if null x' then [] else [x'], dropWhile isSpace cs)
            _          -> ([],       cs)
    splitDomains cs = ([],cs)

merge = intercalate "; "

isExample s = not (null s) && head s == '"'

parseComment ""       = [""]
parseComment (';':cs) = "":parseComment (dropWhile isSpace cs)
parseComment ('"':cs) = case break (=='"') cs of
                          (y,'"':cs) -> case parseComment cs of
                                          (x:xs) -> ('"':y++'"':x):xs
                          _          -> case parseComment cs of
                                          (x:xs) -> (       '"':x):xs
parseComment (c  :cs) = case parseComment cs of
                          (x:xs) -> (c:x):xs

parseExamples []                        = []
parseExamples (l1:l2:l3:l4:l5:l6:ls)
  | take 4 l1 == "abs:" && take 4 l5 == "key:" =
      let (w:ws) = words (drop 5 l5)
          fns    = take (read w) ws
          ts     = case readExpr (drop 5 l1) of
                     Just e  -> [(fns, e)]
                     Nothing -> []
      in ts ++ parseExamples ls
parseExamples (l:ls)                    = parseExamples ls

parseEmbeddings (l:"":ls) = (parseVector l, parseWords ls)
  where
    parseWords []               = []
    parseWords (l1:l2:l3:"":ls) = 
      let hvec = parseVector l2
          mvec = parseVector l3
      in sum hvec `seq` sum mvec `seq` (Embedding l1 hvec mvec):parseWords ls

    parseVector = map read . words :: String -> [Double]
