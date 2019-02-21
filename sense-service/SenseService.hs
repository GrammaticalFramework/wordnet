{-# LANGUAGE CPP, BangPatterns, MonadComprehensions #-}
import PGF2
import Database.Helda
import SenseSchema
import qualified Data.Map as Map
import qualified Data.Vector as Vector
import Control.Monad(foldM,msum)
import Control.Concurrent(forkIO)
import Network.CGI
import Network.FastCGI(runFastCGI,runFastCGIConcurrent')
import System.Environment
import qualified Codec.Binary.UTF8.String as UTF8 (encodeString)
import Text.JSON
import Data.Maybe(mapMaybe)
import Data.List(sortOn,sortBy,delete)
import Data.Char

main = do
  db <- openDB "/home/krasimir/www/semantics.db"
  args <- getArgs
  case args of
    ["report"] -> doReport db
    _          -> do st <- runHelda db ReadOnlyMode $ do
                             [cs] <- select [Vector.fromList cs | (_,cs) <- from coefficients]
                             let avg x y = (x+y)/2
                             funs <- fmap Map.fromList $
                                        select [(fun, (hvec,mvec,vec))
                                                  | (_,Embedding fun hvec' mvec') <- from embeddings
                                                  , let !hvec = Vector.fromList hvec'
                                                        !mvec = Vector.fromList mvec'
                                                        !vec  = Vector.zipWith avg hvec mvec]
                             return (cs,funs)
-- #ifndef mingw32_HOST_OS
--                   runFastCGIConcurrent' forkIO 100 (cgiMain db)
-- #else
                     runFastCGI (handleErrors $ cgiMain db st)
-- #endif
  closeDB db
  where
    doReport db = do
      res <- runHelda db ReadOnlyMode $ 
               select (from checked)
      mapM_ putStrLn (map snd res)


cgiMain :: Database -> Embeddings -> CGI CGIResult
cgiMain db (cs,funs) = do
  mb_s1 <- getInput "lexical_ids"
  mb_s2 <- getInput "check_id"
  case mb_s1 of
    Just s  -> do json <- liftIO (doQuery (words s))
                  outputJSONP json
    Nothing -> case mb_s2 of
                 Just lex_id -> do json <- liftIO (doCheck lex_id)
                                   outputJSONP json
                 Nothing     -> outputNothing
  where
    doQuery lex_ids = do
      senses <- runHelda db ReadOnlyMode $
                  foldM (getSense db) Map.empty lex_ids
      let sorted_senses = (map snd . sortOn fst . map addKey . Map.toList) senses
      return (showJSON (map mkSenseObj sorted_senses))
      where
        mkSenseObj (sense_id,(gloss,synset,lex_ids)) =
          makeObj [("sense_id",showJSON sense_id)
                  ,("synset",showJSON synset)
                  ,("gloss",showJSON gloss)
                  ,("lex_ids",mkLexObj lex_ids)
                  ]

        mkLexObj lex_ids =
          makeObj [(lex_id,mkInfObj domains examples sexamples heads mods rels) | (lex_id,domains,examples,sexamples,heads,mods,rels) <- lex_ids]

        mkInfObj domains examples sexamples heads mods rels =
          makeObj [("domains",  showJSON domains),
                   ("examples", showJSON (map (showExpr []) examples)),
                   ("secondary_examples", showJSON (map (showExpr []) sexamples)),
                   ("heads", makeObj heads),
                   ("modifiers", makeObj mods),
                   ("relations", makeObj rels)
                  ]

        getSense db senses lex_id = do
          lexemes <- select (fromIndexAt lexemes_fun lex_id)
          foldM (getGloss db) senses lexemes

        getGloss db senses (_,Lexeme lex_id sense_id domains ex_ids) = do
          examples  <- select [e | ex_id <- msum (map return ex_ids), e <- fromAt examples ex_id]
          sexamples <- select [e | (id,e) <- fromIndexAt examples_fun lex_id, not (elem id ex_ids)]

          let (heads,mods,rels) =
                case Map.lookup lex_id funs of
                  Just (hvec,mvec,vec) -> let res1  = take 100 (sortBy (\x y -> compare (fst y) (fst x))
                                                                       [res | (fun,(hvec',mvec',_)) <- Map.toList funs
                                                                            , res <- [(prod hvec cs mvec',Left fun)
                                                                                     ,(prod mvec cs hvec',Right fun)]])
                                              heads = [(fun,showJSON prob) | (prob,Right fun) <- res1]
                                              mods  = [(fun,showJSON prob) | (prob,Left  fun) <- res1]

                                              res2  = take 100 (sortOn fst [(dist vec vec',(fun,vec')) | (fun,(_,_,vec')) <- Map.toList funs])
                                              rels  = [(fun,showJSON (Vector.toList vec)) | (prob,(fun,vec)) <- res2]
                                          in (heads,mods,rels)
                  Nothing              -> ([],[],[])

          case Map.lookup sense_id senses of
            Just (gloss,synset,lex_ids) -> return (Map.insert sense_id (gloss,synset,(lex_id,domains,examples,sexamples,heads,mods,rels):lex_ids) senses)
            Nothing                     -> do [Synset offset gloss] <- select (fromAt synsets sense_id)
                                              synset <- select [lex_fun | (_,Lexeme lex_fun _ _ _) <- fromIndexAt lexemes_synset sense_id]
                                              return (Map.insert sense_id (gloss,synset,[(lex_id,domains,examples,sexamples,heads,mods,rels)]) senses)

        prod v1 v2 v3 = Vector.sum (Vector.zipWith3 (\x y z -> x*y*z) v1 v2 v3)

        dist v1 v2 = Vector.sum (Vector.zipWith diff v1 v2)
          where
            diff x y = (x-y)^2

        addKey (sense_id,(gloss,synset,lex_ids)) = (fst (head key_lex_ids), (sense_id,(gloss,synset,map snd key_lex_ids)))
          where
            key_lex_ids = sortOn fst [(toKey lex_id,x) | x@(lex_id,_,_,_,_,_,_) <- lex_ids]

            toKey lex_id = (reverse rid,reverse rcat,read ('0':reverse rn)::Int)
              where
                s0 = reverse lex_id
                (rcat,'_':s1) = break (=='_') s0
                (rn,rid) = break (not . isDigit) s1

    doCheck lex_id =
      runHelda db ReadWriteMode $ do
        update lexemes (\id lexeme -> lexeme{domains=delete "unchecked" (domains lexeme)}) (fromIndexAt lexemes_fun lex_id)
        insert checked lex_id
        return ()

type Embeddings = (Vector.Vector Double
                  ,Map.Map Fun (Vector.Vector Double,Vector.Vector Double,Vector.Vector Double)
                  )

outputJSONP :: JSON a => a -> CGI CGIResult
outputJSONP = outputEncodedJSONP . encode

outputEncodedJSONP :: String -> CGI CGIResult
outputEncodedJSONP json = 
    do mc <- getInput "jsonp"
       let (ty,str) = case mc of
                        Nothing -> ("json",json)
                        Just c  -> ("javascript",c ++ "(" ++ json ++ ")")
           ct = "application/"++ty++"; charset=utf-8"
       outputText ct str

outputText ct = outputStrict ct . UTF8.encodeString

outputStrict :: String -> String -> CGI CGIResult
outputStrict ct x = do setHeader "Content-Type" ct
                       setHeader "Content-Length" (show (length x))
                       setXO
                       output x

setXO = setHeader "Access-Control-Allow-Origin" "*"
