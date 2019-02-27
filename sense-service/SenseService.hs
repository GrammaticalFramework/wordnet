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
                             [cs] <- select [cs | (_,cs) <- from coefficients]

                             let norm v = zipWith (\c x -> (c*x) / len) cs v
                                   where
                                     len = sum (zipWith (*) cs v)

                             funs <- fmap Map.fromList $
                                        select [(fun, (hvec,mvec,vec))
                                                  | (_,Embedding fun hvec' mvec') <- from embeddings
                                                  , let !hvec = Vector.fromList hvec'
                                                        !mvec = Vector.fromList mvec'
                                                        !vec  = Vector.fromList (norm (hvec'++mvec'))]
                             return (Vector.fromList cs,funs)
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
  mb_s2 <- getInput "context_id"
  mb_s3 <- getInput "gloss_id"
  mb_s4 <- getInput "check_id"
  case mb_s1 of
    Just s  -> do json <- liftIO (doQuery (words s))
                  outputJSONP json
    Nothing -> case mb_s2 of
                 Just lex_id -> do json <- liftIO (doContext lex_id)
                                   outputJSONP json
                 Nothing     -> case mb_s3 of
                                  Just lex_id -> do json <- liftIO (doGloss lex_id)
                                                    outputJSONP json
                                  Nothing     -> case mb_s4 of
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
                  ,("synset",makeObj [(lex_fun,showJSON domains) | (lex_fun,domains) <- synset])
                  ,("gloss",showJSON gloss)
                  ,("lex_ids",mkLexObj lex_ids)
                  ]

        mkLexObj lex_ids =
          makeObj [(lex_id,mkInfObj domains examples sexamples) | (lex_id,domains,examples,sexamples) <- lex_ids]

        mkInfObj domains examples sexamples =
          makeObj [("domains",  showJSON domains),
                   ("examples", showJSON (map (showExpr []) examples)),
                   ("secondary_examples", showJSON (map (showExpr []) sexamples))
                  ]

        getSense db senses lex_id = do
          lexemes <- select (fromIndexAt lexemes_fun lex_id)
          foldM (getGloss db) senses lexemes

        getGloss db senses (_,Lexeme lex_id sense_id domains ex_ids) = do
          examples  <- select [e | ex_id <- msum (map return ex_ids), e <- fromAt examples ex_id]
          sexamples <- select [e | (id,e) <- fromIndexAt examples_fun lex_id, not (elem id ex_ids)]

          case Map.lookup sense_id senses of
            Just (gloss,synset,lex_ids) -> return (Map.insert sense_id (gloss,synset,(lex_id,domains,examples,sexamples):lex_ids) senses)
            Nothing                     -> do [Synset offset gloss] <- select (fromAt synsets sense_id)
                                              synset <- select [(lex_fun,domains) | (_,Lexeme lex_fun _ domains _) <- fromIndexAt lexemes_synset sense_id]
                                              return (Map.insert sense_id (gloss,synset,[(lex_id,domains,examples,sexamples)]) senses)

        addKey (sense_id,(gloss,synset,lex_ids)) = (fst (head key_lex_ids), (sense_id,(gloss,synset,map snd key_lex_ids)))
          where
            key_lex_ids = sortOn fst [(toKey lex_id,x) | x@(lex_id,_,_,_) <- lex_ids]

            toKey lex_id = (reverse rid,reverse rcat,read ('0':reverse rn)::Int)
              where
                s0 = reverse lex_id
                (rcat,'_':s1) = break (=='_') s0
                (rn,rid) = break (not . isDigit) s1

    doContext lex_id =
      let (ctxt,rels) =
             case Map.lookup lex_id funs of
               Just (hvec,mvec,vec) -> let res1  = take 200 (sortBy (\x y -> compare (fst y) (fst x))
                                                                    [res | (fun,(hvec',mvec',_)) <- Map.toList funs
                                                                         , res <- [(prod hvec cs mvec',Left fun)
                                                                                  ,(prod mvec cs hvec',Right fun)]])
                                           ctxt = [mkFunProb fun prob | (prob,fun) <- res1]

                                           res2  = take 200 (sortOn fst [(dist vec vec',(fun,vec')) | (fun,(_,_,vec')) <- Map.toList funs])
                                           rels  = [mkFunVec fun (Vector.toList vec) | (dist,(fun,vec)) <- res2]
                                       in (ctxt,rels)
               Nothing              -> ([],[])
      in return (makeObj [("context",   showJSON ctxt),
                          ("relations", showJSON rels)
                         ])
      where
        prod v1 v2 v3 = Vector.sum (Vector.zipWith3 (\x y z -> x*y*z) v1 v2 v3)

        dist v1 v2 = Vector.sum (Vector.zipWith diff v1 v2)
          where
            diff x y = (x-y)^2

        mkFunProb fun prob = 
          case fun of
            Left  fun -> makeObj [("mod", showJSON fun),("prob", showJSON prob)]
            Right fun -> makeObj [("head",showJSON fun),("prob", showJSON prob)]
        mkFunVec  fun vec  = makeObj [("fun",showJSON fun),("vec",  showJSON vec)]

    doGloss lex_id = do
      glosses <- runHelda db ReadOnlyMode $
                    select [gloss s | (_,lex) <- fromIndexAt lexemes_fun lex_id,
                                      s <- fromAt synsets (synset lex)]
      return (showJSON glosses)

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
