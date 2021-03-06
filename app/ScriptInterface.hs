module ScriptInterface
    ( scriptInterface
    , opaqueToAction
    , loadConfig
    , loadConfigAction
    , rawKeys
    , liftAction
    , evalHook
    -- Temporary
    , keyNameToEvent
    , partToModifier
    , partToKey
    , partsToEvent
    ) where
import Brick.Main (halt, continue)
import Brick.Types (EventM, Next)
import Control.Monad.IO.Class (liftIO)
import Data.Array (elems)
import Data.Either (lefts, rights)
import Data.Maybe
import Data.List (isInfixOf, intercalate)
import Data.List.Split (splitOn)
import qualified Data.Map as M
import qualified Graphics.Vty as V
import Language.Scheme.Core
import Language.Scheme.Types hiding (bindings)
import Language.Scheme.Variables
import Lens.Micro ((&), (.~), (^.))
import Parchment.FString
import Parchment.Session
import Parchment.Util
import System.Environment.XDG.BaseDir
import qualified Text.Regex.TDFA.String as R

scriptInterface :: IO Env
scriptInterface = r5rsEnv >>= flip extendEnv
    [ ((varNamespace, "backspace-input"), sessFuncToOpaque backspaceInput)
    , ((varNamespace, "delete-input"), sessFuncToOpaque deleteInput)
    , ((varNamespace, "quit"), actionToOpaque $ returnMaybe . const Nothing)
    , ((varNamespace, "clear-input"), sessFuncToOpaque clearInput)
    , ((varNamespace, "page-up"), sessFuncToOpaque pageUp)
    , ((varNamespace, "page-down"), sessFuncToOpaque pageDown)
    , ((varNamespace, "history-older"), sessFuncToOpaque historyOlder)
    , ((varNamespace, "history-newer"), sessFuncToOpaque historyNewer)
    , ((varNamespace, "do-nothing"), sessFuncToOpaque id)
    , ((varNamespace, "reload-config"), actionToOpaque loadConfigAction)
    , ((varNamespace, "toggle-buffer"), sessFuncToOpaque toggleBuffer)
    , ((varNamespace, "add-to-history"), CustFunc addToHistoryWrapper)
    , ((varNamespace, "send"), CustFunc sendToServerWrapper)
    , ((varNamespace, "send-gmcp"), CustFunc sendGmcpWrapper)
    , ((varNamespace, "bind"), CustFunc bindWrapper)
    , ((varNamespace, "scroll-history"), CustFunc scrollHistoryWrapper)
    , ((varNamespace, "scroll-lines"), CustFunc scrollLinesWrapper)
    , ((varNamespace, "search-backwards"), CustFunc searchBackwardsWrapper)
    , ((varNamespace, "print"), CustFunc (writeBufferWrapper debugBufferNum))
    , ((varNamespace, "println"), CustFunc (writeBufferLnWrapper debugBufferNum))
    , ((varNamespace, "write"), CustFunc (writeBufferWrapper mainBufferNum))
    , ((varNamespace, "writeln"), CustFunc (writeBufferLnWrapper mainBufferNum))
    , ((varNamespace, "add-input"), CustFunc addInputWrapper)
    , ((varNamespace, "move-cursor"), CustFunc moveCursorWrapper)
    , ((varNamespace, "add-world-room"), CustFunc addWorldRoomWrapper)
    , ((varNamespace, "composite"), CustFunc compositeAction)
    , ((varNamespace, "string-repr"), CustFunc stringRepr)
    , ((varNamespace, "make-hash"), CustFunc makeHash)
    , ((varNamespace, "hash-contains?"), CustFunc hashContains)
    , ((varNamespace, "hash-get"), CustFunc hashGet)
    , ((varNamespace, "hash-set"), CustFunc hashSet)
    , ((varNamespace, "hash-keys"), CustFunc hashKeys)
    , ((varNamespace, "string-matches"), CustFunc stringMatches)]

-- Characters displayed directly.
rawKeys :: String
rawKeys = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()_+-=_+[]\\;',./{}|:\"<>? `~"

-- Evals the given Scheme hook and runs the returned action.
evalHook :: String -> [LispVal] -> Sess -> IOMaybe Sess
evalHook name args sess = do
    let to_eval = List $ (Atom name) : args
    res <- liftIO $ evalLisp' (sess ^. scm_env) to_eval
    case res of
            Right l -> do
                case l of
                    Opaque _ -> (opaqueToAction l) sess
                    x -> returnMaybe . Just $
                        sess & logError ("Expected an action, found: " ++ show x)
            Left err -> returnMaybe . Just $ sess & logError (show err)

-- Loads the config file. Returns the environment and optionally any errors.
loadConfig :: IO (Env, Maybe String)
loadConfig = do
    scmEnv <- scriptInterface
    configPath <- getUserConfigFile "parchment" "config.scm"
    let conf = List [Atom "include", String configPath]
    res <- evalLisp' scmEnv conf
    case res of
         Left err -> return (scmEnv, Just $ show err)
         Right _ -> return (scmEnv, Nothing)

loadConfigAction :: Sess -> IOMaybe Sess
loadConfigAction sess = do
    (scmEnv, configErr) <- liftIO loadConfig
    case configErr of
        Just err -> returnMaybe . Just . logError ("Config error: " ++ err) $ sess
        Nothing -> sess & scm_env .~ scmEnv
                        & evalHook "load-hook" []

-- Helper functions for converting between lisp types and Sess actions.
opaqueToAction :: LispVal -> Sess -> IOMaybe Sess
opaqueToAction lv
    | Right f <- action_res = f
    | Left err <- action_res = returnMaybe . Just . logError ("Error: " ++ show err)
    where action_res = fromOpaque lv :: ThrowsError (Sess -> IOMaybe Sess)

actionToOpaque :: (Sess -> IOMaybe Sess) -> LispVal
actionToOpaque = toOpaque

sessFuncToOpaque :: (Sess -> Sess) -> LispVal
sessFuncToOpaque sf = actionToOpaque $ returnMaybe . Just . sf

ioSessFuncToOpaque :: (Sess -> IO Sess) -> LispVal
ioSessFuncToOpaque sf = actionToOpaque $ \sess -> do
    res <- liftIO $ sf sess
    returnMaybe . Just $ res

liftAction :: (Sess -> IOMaybe Sess) -> Sess -> EventM () (Next Sess)
liftAction act sess = do
    res <- liftIO . runIOMaybe $ act sess
    case res of
        Nothing -> halt sess
        Just s -> continue s

-- Convert key name to event.
keyNameToEvent :: String -> Maybe V.Event
keyNameToEvent = partsToEvent . splitOn "-"

partsToEvent :: [String] -> Maybe V.Event
partsToEvent [] = Nothing
partsToEvent [key] = partToKey key >>= return . flip V.EvKey []
partsToEvent parts = do
    let mods = map fromJust . filter isJust $ map partToModifier (init parts)
    partToKey (last parts) >>= return . flip V.EvKey mods

partToKey :: String -> Maybe V.Key
partToKey s = case s of
                   "Esc" -> Just V.KEsc
                   "Backspace" -> Just V.KBS
                   "Enter" -> Just V.KEnter
                   "Left" -> Just V.KLeft
                   "Right" -> Just V.KRight
                   "Up" -> Just V.KUp
                   "Down" -> Just V.KDown
                   "Backtab" -> Just V.KBackTab
                   "Delete" -> Just V.KDel
                   "PrintScreen" -> Just V.KPrtScr
                   "F1" -> Just $ V.KFun 1
                   "F2" -> Just $ V.KFun 2
                   "F3" -> Just $ V.KFun 3
                   "F4" -> Just $ V.KFun 4
                   "F5" -> Just $ V.KFun 5
                   "F6" -> Just $ V.KFun 6
                   "F7" -> Just $ V.KFun 7
                   "F8" -> Just $ V.KFun 8
                   "F9" -> Just $ V.KFun 9
                   "F10" -> Just $ V.KFun 10
                   "F11" -> Just $ V.KFun 11
                   "F12" -> Just $ V.KFun 12
                   "PageUp" -> Just V.KPageUp
                   "PageDown" -> Just V.KPageDown
                   "Pause" -> Just V.KPause
                   "Insert" -> Just V.KIns
                   "Home" -> Just V.KHome
                   "End" -> Just V.KEnd
                   ch | ((length ch == 1) && (ch `isInfixOf` rawKeys)) ->
                       Just $ V.KChar (ch !! 0)
                   _ -> Nothing

partToModifier :: String -> Maybe V.Modifier
partToModifier s = case s of
                        "S" -> Just V.MShift
                        "C" -> Just V.MCtrl
                        "M" -> Just V.MMeta
                        "A" -> Just V.MAlt
                        _ -> Nothing

-- === BINDING WRAPPERS. ===
addInputWrapper :: [LispVal] -> IOThrowsError LispVal
addInputWrapper [(Char c)] = liftThrows . Right . sessFuncToOpaque $ addInput c
addInputWrapper _ = liftThrows . Left . Default $ "Usage: (add-input <char>)"

moveCursorWrapper :: [LispVal] -> IOThrowsError LispVal
moveCursorWrapper [(Number n)] = liftThrows . Right . sessFuncToOpaque . moveCursor $
    fromIntegral n
moveCursorWrapper _ = liftThrows . Left . Default $ "Usage: (move-cursor <num>)"

scrollHistoryWrapper :: [LispVal] -> IOThrowsError LispVal
scrollHistoryWrapper [(Number n)] = liftThrows . Right . sessFuncToOpaque . scrollHistory $
    fromIntegral n
scrollHistoryWrapper _ = liftThrows . Left . Default $ "Usage: (scroll-history <num>)"

scrollLinesWrapper :: [LispVal] -> IOThrowsError LispVal
scrollLinesWrapper [(Number n)] = liftThrows . Right . sessFuncToOpaque . scrollLines $
    fromIntegral n
scrollLinesWrapper _ = liftThrows . Left . Default $ "Usage: (scroll-lines <num>)"

searchBackwardsWrapper :: [LispVal] -> IOThrowsError LispVal
searchBackwardsWrapper [(String s)] =
    liftThrows . Right . sessFuncToOpaque $ searchCurrent
    where searchCurrent sess = searchBackwards (currentBufferNum sess) s $ sess
searchBackwardsWrapper _ = liftThrows . Left . Default $
    "Usage: (search-backwards <string>)"

addToHistoryWrapper :: [LispVal] -> IOThrowsError LispVal
addToHistoryWrapper [(String s)] = liftThrows . Right . sessFuncToOpaque . addToHistory $ s
addToHistoryWrapper _ = liftThrows . Left . Default $ "Usage: (add-to-history str)"

writeBufferWrapper :: Int -> [LispVal] -> IOThrowsError LispVal
writeBufferWrapper bnum [(String s)] = liftThrows . Right . sessFuncToOpaque .
    writeBuffer bnum $ formatStr s
writeBufferWrapper _ _ = liftThrows . Left . Default $ "Usage: (print str)"

writeBufferLnWrapper :: Int -> [LispVal] -> IOThrowsError LispVal
writeBufferLnWrapper bnum [(String s)] = liftThrows . Right . sessFuncToOpaque .
    writeBufferLn bnum $ formatStr s
writeBufferLnWrapper _ _ = liftThrows . Left . Default $ "Usage: (println str)"

sendToServerWrapper :: [LispVal] -> IOThrowsError LispVal
sendToServerWrapper [(String s)] = liftThrows . Right . ioSessFuncToOpaque $
    sendToServer s
sendToServerWrapper _ = liftThrows . Left . Default $ "Usage: (send <string>)"

sendGmcpWrapper :: [LispVal] -> IOThrowsError LispVal
sendGmcpWrapper [(String s)] = liftThrows . Right . ioSessFuncToOpaque $ sendGmcp s
sendGmcpWrapper _ = liftThrows . Left . Default $ "Usage: (send-gmcp <string>)"

addWorldRoomUsage = "Usage: (add-world-room id attrs edges) where edges is a list of (Number, Number, String)"
addWorldRoomWrapper :: [LispVal] -> IOThrowsError LispVal
addWorldRoomWrapper [(Number raw_id), (HashTable raw_attrs), (List raw_edges)]
    | (length . lefts $ edges) == 0 = liftThrows . Right . sessFuncToOpaque $
        addWorldRoom id attrs $ rights edges
    | otherwise = liftThrows . Left . Default $ addWorldRoomUsage
    where id = fromIntegral raw_id
          attrs = M.fromList $ zip (map toStr $ M.keys raw_attrs)
                                   (map toStr $ M.elems raw_attrs)
          listToEdge (List [(Number raw_source), (Number raw_dest), (String raw_tag)]) =
              Right $ (fromIntegral raw_source, fromIntegral raw_dest, raw_tag)
          listToEdge _ = Left . Default $ addWorldRoomUsage
          edges = map listToEdge raw_edges
addWorldRoomWrapper _ = liftThrows . Left . Default $ addWorldRoomUsage

bindWrapper :: [LispVal] -> IOThrowsError LispVal
bindWrapper [(String key), act] =
    case keyNameToEvent key of
         Nothing -> liftThrows . Left . Default $ "Error: invalid key: " ++ key
         Just k -> liftThrows . Right . sessFuncToOpaque . bind k $
             liftAction . opaqueToAction $ act
bindWrapper _ = liftThrows . Left . Default $ "Usage: (bind <key> <action>)"

compositeAction :: [LispVal] -> IOThrowsError LispVal
compositeAction [(List l)] = liftThrows . Right . actionToOpaque . chainM $
    map opaqueToAction l
compositeAction _ = liftThrows . Left . Default $ "Usage: (composite <list>)"

toStr :: LispVal -> String
-- TODO: Fix this awful hack.. doubling up left braces so that color parsing works.
toStr (HashTable ht) = (++) "{{" . flip (++) "}" . intercalate ", " .
    map (\(k,v) -> (toStr k) ++ ": " ++ (toStr v)) $ M.assocs ht
toStr v = show v

stringRepr :: [LispVal] -> IOThrowsError LispVal
stringRepr [v] = liftThrows . Right . String $ toStr v
stringRepr _ = liftThrows . Left . Default $ "Usage: (string-repr <val>)"

makeHash :: [LispVal] -> IOThrowsError LispVal
makeHash [] = liftThrows . Right $ HashTable M.empty
makeHash _ = liftThrows . Left . Default $ "Usage: (make-hash)"

hashContains :: [LispVal] -> IOThrowsError LispVal
hashContains [(HashTable ht), key] = liftThrows . Right . Bool $ M.member key ht
hashContains _ = liftThrows . Left . Default $ "Usage: (hash-contains? ht key)"

hashGet :: [LispVal] -> IOThrowsError LispVal
hashGet [(HashTable ht), key]
    | (Just val) <- res = liftThrows . Right $ val
    | Nothing <- res = liftThrows . Right . Bool $ False
    where res = M.lookup key ht
hashGet _ = liftThrows . Left . Default $ "Usage: (hash-get ht key)"

hashSet :: [LispVal] -> IOThrowsError LispVal
hashSet [(HashTable ht), key, val] = liftThrows . Right . HashTable $
    M.insert key val ht
hashSet _ = liftThrows . Left . Default $ "Usage: (hash-set ht key val)"

hashKeys :: [LispVal] -> IOThrowsError LispVal
hashKeys [(HashTable ht)] = liftThrows . Right . List $ M.keys ht
hashKeys _ = liftThrows . Left . Default $ "Usage: (hash-keys ht)"

stringMatches :: [LispVal] -> IOThrowsError LispVal
stringMatches [(String s), (String pattern)] =
    case R.compile regexCompOpt regexExecOpt pattern of
        Left err -> liftThrows . Left . Default $ "Error: " ++ show err
        Right regex -> case R.execute regex s of
                            Left _ -> liftThrows . Right . Bool $ False
                            Right Nothing -> liftThrows . Right . Bool $ False
                            Right (Just ma) -> liftThrows . Right . List $ matches
                                where extractSub ind = String . take (snd ind)
                                                              . drop (fst ind) $ s
                                      matches = map extractSub $ elems ma
stringMatches _ = liftThrows . Left . Default $ "Usage: (string-matches str pattern)"
