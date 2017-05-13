{-# LANGUAGE TemplateHaskell #-}

module Parchment.Session
    ( Sess(..)
    , Settings(..)
    , initialSession
    , defaultSettings
    , addInput
    , backspaceInput
    , deleteInput
    , sendToServer
    , sendRawToServer
    , clearInput
    , moveCursor
    , writeBuffer
    , writeBufferLn
    , bind
    , getInput
    , addToHistory
    , receiveServerData
    , pageUp
    , pageDown
    , scrollLines
    , historyOlder
    , historyNewer
    , historyNewest
    , scrollHistory
    , highlightStr
    , unhighlightStr
    , searchBackwards
    -- lenses
    , settings
    , hostname
    , port
    , buffer
    , buf_lines
    , cursor
    , scroll_loc
    , scm_env
    , bindings
    , recv_state
    , telnet_cmds
    , text
    ) where

import Brick.Types (EventM, Next)
import Brick.Util (clamp)
import Control.Concurrent.STM.TQueue
import Control.Monad.STM (atomically)
import Data.Array ((!))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (foldl', splitAt)
import qualified Data.Map.Lazy as Map
import Data.Maybe (isJust, fromJust)
import qualified Data.Sequence as S
import Data.Word (Word8)
import qualified Graphics.Vty as V
import Language.Scheme.Types hiding (bindings)
import Lens.Micro ((.~), (^.), (&), (%~), ix)
import Lens.Micro.TH (makeLenses)
import Parchment.EscSeq
import Parchment.FString
import Parchment.ParseState
import qualified Parchment.RingBuffer as RB
import Parchment.Telnet
import Parchment.Util
import Text.Parsec hiding (Error, getInput)
import qualified Text.Regex.TDFA.String as R

data Sess = Sess
    { _settings :: Settings
    , _buffer :: RB.RingBuffer FString
    , _buf_lines :: Int
    , _scroll_loc :: Int
    , _history :: [String]
    , _history_loc :: Int
    , _cursor :: Int
    , _bindings :: Map.Map V.Event (Sess -> EventM () (Next Sess))
    , _recv_state :: RecvState
    , _send_queue :: TQueue BS.ByteString
    , _scm_env :: Env
    , _last_search :: Maybe SearchResult
    }
data Settings = Settings
    { _hostname :: String
    , _port :: Int
    }
defaultSettings :: String -> Int -> Settings
defaultSettings host port = Settings
    { _hostname = host
    , _port = port
    }
data SearchResult = SearchResult
    { _search :: String
    , _line :: Int
    , _start :: Int
    , _end :: Int
    }
searchResult :: String -> Int -> Int -> Int -> SearchResult
searchResult search line start end = SearchResult
    { _search = search
    , _line = line
    , _start = start
    , _end = end
    }
data RecvState = RecvState
    { _text :: FString
    , _telnet_state :: ParseState BS.ByteString
    , _telnet_cmds :: [BS.ByteString]
    , _esc_seq_state :: ParseState BS.ByteString
    , _char_attr :: V.Attr
    }
blankRecvState :: RecvState
blankRecvState = RecvState
    { _text = []
    , _telnet_state = NotInProgress
    , _telnet_cmds = []
    , _esc_seq_state = NotInProgress
    , _char_attr = V.defAttr
    }
makeLenses ''Sess
makeLenses ''Settings
makeLenses ''SearchResult
makeLenses ''RecvState

-- Initial state of the session data.
initialSession :: Settings ->
    TQueue BS.ByteString ->
    Map.Map V.Event (Sess -> EventM () (Next Sess)) ->
    Env ->
    Sess
initialSession settings q bindings scm_env = Sess
    { _settings = settings
    , _buffer = flip RB.push emptyF $ RB.newInit emptyF 50000 -- lines in buffer
    , _buf_lines = 0
    , _scroll_loc = 0
    , _history = [""]
    , _history_loc = 0
    , _cursor = 0
    , _bindings = bindings
    , _recv_state = blankRecvState
    , _send_queue = q
    , _scm_env = scm_env
    , _last_search = Nothing
    }

-- === ACTIONS ===
getInput :: Sess -> String
getInput sess = sess ^. (history . ix (sess ^. history_loc))

addInput :: Char -> Sess -> Sess
addInput ch sess = sess & history . ix (sess ^. history_loc) .~ left ++ ch:right
                        & moveCursor 1
    where input = getInput sess
          (left, right) = splitAt (sess ^. cursor) input

backspaceInput :: Sess -> Sess
backspaceInput sess
    | left == "" = sess
    | otherwise = sess & history . ix (sess ^. history_loc) .~ init left ++ right
                       & moveCursor (-1)
    where input = getInput sess
          (left, right) = splitAt (sess ^. cursor) input

deleteInput :: Sess -> Sess
deleteInput sess
    | right == "" = sess
    | otherwise = sess & history . ix (sess ^. history_loc) .~ left ++ tail right
    where input = getInput sess
          (left, right) = splitAt (sess ^. cursor) input

clearInput :: Sess -> Sess
clearInput sess =
    sess & history . ix (sess ^. history_loc) .~ ""
         & cursor .~ 0

moveCursor :: Int -> Sess -> Sess
moveCursor n sess = sess & cursor %~ clamp 0 (length $ getInput sess) . (+) n

bind :: V.Event -> (Sess -> EventM () (Next Sess)) -> Sess -> Sess
bind event action sess = sess & bindings %~ Map.insert event action

writeBuffer :: FString -> Sess -> Sess
writeBuffer str sess = foldl' addBufferChar sess str

writeBufferLn :: FString -> Sess -> Sess
writeBufferLn str = writeBuffer (str ++ [FChar { _ch = '\n', _attr = V.defAttr}])

-- Highlight line, start index, end index.
highlightStr :: (Int, Int, Int) -> Sess -> Sess
highlightStr = flip modifyBuffer $ withStyle V.standout

-- Unhighlight line, start index, end index.
unhighlightStr :: (Int, Int, Int) -> Sess -> Sess
unhighlightStr = flip modifyBuffer $ withStyle V.defaultStyleMask

searchBackwards :: String -> Sess -> Sess
searchBackwards str sess =
    case R.compile regexCompOpt regexExecOpt str of
         Left err -> flip writeBufferLn sess . colorize V.red $ "Regex error: " ++ err
         Right regex -> case searchBackwardsHelper regex (sess ^. buffer) (startLine sess) of
                             Just sr@(line,_,_) -> highlightStr sr . setSearchRes str (Just sr) .
                                 unhighlightPrevious . scrollLines
                                     (line - (sess ^. scroll_loc)) $ sess
                             Nothing -> writeBufferLn
                                (colorize V.red $ "Search string not found!") .
                                 setSearchRes str Nothing . unhighlightPrevious $
                                    sess & scroll_loc .~ 0
    where startLine sess =
              case sess ^. last_search of
                   Nothing -> 0
                   Just sr -> if (sr ^. search) == str then (sr ^. line) + 1 else 0
          unhighlightPrevious sess =
              case sess ^. last_search of
                   Nothing -> sess
                   Just sr ->
                       unhighlightStr ((sr ^. line), (sr ^. start), (sr ^. end)) $ sess
          setSearchRes str (Just (line, start, end)) sess =
              sess & last_search .~ Just (searchResult str line start end)
          setSearchRes _ Nothing sess = sess & last_search .~ Nothing

scrollLines :: Int -> Sess -> Sess
scrollLines n sess = sess & scroll_loc %~
    (\sl -> clamp 0 (RB.length (sess ^. buffer) - (sess ^. buf_lines)) $ sl + n)

pageUp :: Sess -> Sess
pageUp = scrollLines 10

pageDown :: Sess -> Sess
pageDown = scrollLines $ -10

addToHistory :: String -> Sess -> Sess
addToHistory s sess = sess &
    history %~ (++ [s, ""]) . init &
    history_loc .~ (length $ sess ^. history) & -- based on old history length
    cursor .~ 0

scrollHistory :: Int -> Sess -> Sess
scrollHistory n sess = sess &
    history_loc .~ new_loc &
    cursor .~ new_cursor
    where new_loc = clampExclusive 0 (length $ sess ^. history) $ (sess ^. history_loc) + n
          new_cursor = length $ sess ^. (history . ix new_loc)

historyOlder :: Sess -> Sess
historyOlder = scrollHistory $ -1

historyNewer :: Sess -> Sess
historyNewer = scrollHistory 1

historyNewest :: Sess -> Sess
historyNewest sess = scrollHistory (length $ sess ^. history) sess

sendToServer :: String -> Sess -> IO Sess
sendToServer str sess = do
    atomically $ writeTQueue (sess ^. send_queue) (BSC.pack $ str ++ "\r\n")
    return sess

sendRawToServer :: [Word8] -> Sess -> IO Sess
sendRawToServer bytes sess = do
    atomically $ writeTQueue (sess ^. send_queue) $ BS.pack bytes
    return sess

receiveServerData :: Sess -> BS.ByteString -> Sess
receiveServerData sess bs =
    sess & recv_state %~ \rs -> foldl handleServerByte rs $ BS.unpack bs

-- === HELPER FUNCTIONS ===
-- (line, start index, end index), modification func, session
modifyBuffer :: (Int, Int, Int) -> (FChar -> FChar) -> Sess -> Sess
modifyBuffer (line, start, end) func sess =
    sess & buffer %~ \buf -> RB.update buf line new_str
    where line_str = (sess ^. buffer) RB.! line
          replaceAtIndex f n ls = a ++ ((f item):b)
              where (a, (item:b)) = splitAt n ls
          new_str = (foldr (flip (.)) id $ flip map [start..end] $
                    replaceAtIndex func) line_str

-- Input: Search string, buffer, starting line.
-- Returns: Line, start index, end index if found; Nothing otherwise.
searchBackwardsHelper :: R.Regex -> RB.RingBuffer FString -> Int -> Maybe (Int, Int, Int)
searchBackwardsHelper r buf start_line =
    case S.findIndexL isJust search_results of
         Nothing -> Nothing
         Just idx -> Just (start_line + idx, start, start + len - 1)
             where (start, len) = fromJust (S.index search_results idx)
    where search_results = fmap (findInFString r) . RB.drop start_line $ buf

-- Returns (start, length) if found; Nothing otherwise.
findInFString :: R.Regex -> FString -> Maybe (Int, Int)
findInFString r fs =
    case R.execute r $ removeFormatting fs of
         Left _ -> Nothing
         Right Nothing -> Nothing
         Right (Just ma) -> Just $ ma ! 0

handleServerByte :: RecvState -> Word8 -> RecvState
handleServerByte recv_state b
    | t@(InProgress _) <- new_telnet = recv_state & telnet_state .~ t
    | t@(Success cmd) <- new_telnet = recv_state & telnet_state .~ t
                                                 & telnet_cmds %~ flip (++) [cmd]
    | e@(InProgress _) <- new_esc_seq = recv_state & esc_seq_state .~ e
    | e@(Success seq) <- new_esc_seq = recv_state & esc_seq_state .~ e
                                                  & char_attr %~ \ca ->
                                                                   updateCharAttr ca seq
    | otherwise = recv_state & text %~ ((:)
        FChar { _ch = BSC.head . BS.singleton $ b , _attr = (recv_state ^. char_attr)})
    where new_telnet = parseTelnet (recv_state ^. telnet_state) b
          new_esc_seq = parseEscSeq (recv_state ^. esc_seq_state) b

addBufferChar :: Sess -> FChar -> Sess
addBufferChar sess c
    -- Newlines move to next line.
    | (_ch c) == '\n' = sess & buffer %~ (\buf -> RB.push buf emptyF)
                             & last_search %~ updateSearchResult
    -- Throw out carriage returns.
    | (_ch c) == '\r' = sess
    -- Add char to end of last line.
    | otherwise = sess & buffer %~ \buf -> RB.update buf 0 ((buf RB.! 0) ++ [c])
    where updateSearchResult :: Maybe SearchResult -> Maybe SearchResult
          updateSearchResult Nothing = Nothing
          updateSearchResult (Just res)
              -- Search result will get pushed out of the buffer; flush it.
              | (res ^. line) + 1 >= RB.length (sess ^. buffer) = Nothing
              -- Account for new line in the search result.
              | otherwise = Just $ res & line %~ (+1)

clampExclusive :: Int -> Int -> Int -> Int
clampExclusive min max = clamp min (max - 1)

updateCharAttr :: V.Attr -> BS.ByteString -> V.Attr
updateCharAttr attr seq =
    case parse escSeqPartParser "error" (BSC.unpack seq) of
         Right [] -> V.defAttr -- handle \ESC[m case
         Right parts -> foldr (flip (.)) id (map escSeqPartTransform parts) attr
         Left _ -> attr

escSeqPartTransform :: String -> V.Attr -> V.Attr
escSeqPartTransform s =
    case s of
        "0" -> const V.defAttr
        "1" -> flip V.withStyle V.bold
        "30" -> flip V.withForeColor V.black
        "31" -> flip V.withForeColor V.red
        "32" -> flip V.withForeColor V.green
        "33" -> flip V.withForeColor V.yellow
        "34" -> flip V.withForeColor V.blue
        "35" -> flip V.withForeColor V.magenta
        "36" -> flip V.withForeColor V.cyan
        "37" -> flip V.withForeColor V.white
        "39" -> \a -> V.Attr
            { V.attrStyle = (V.attrStyle a)
            , V.attrForeColor = V.Default
            , V.attrBackColor = (V.attrBackColor a)
            }
        "40" -> flip V.withBackColor V.black
        "41" -> flip V.withBackColor V.red
        "42" -> flip V.withBackColor V.green
        "43" -> flip V.withBackColor V.yellow
        "44" -> flip V.withBackColor V.blue
        "45" -> flip V.withBackColor V.magenta
        "46" -> flip V.withBackColor V.cyan
        "47" -> flip V.withBackColor V.white
        "49" -> \a -> V.Attr
            { V.attrStyle = (V.attrStyle a)
            , V.attrForeColor = (V.attrForeColor a)
            , V.attrBackColor = V.Default
            }
        _ -> id
