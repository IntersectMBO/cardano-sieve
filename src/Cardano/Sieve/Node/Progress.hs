-- | Sync progress reporting: the rolling counters behind the periodic
-- heartbeat line, and the timestamped log line everything is printed with.
module Cardano.Sieve.Node.Progress
  ( Progress
  , newProgress
  , tick
  , summarise
  , heartbeatSeconds
  , logLine
  , logStage
  , logWarn
  , commas
  , duration
  )
where

import Cardano.Slotting.Slot (SlotNo, unSlotNo)

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Maybe (isNothing)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToLocalTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stdout)

-- | Rolling counters behind the periodic sync heartbeat.
--
-- A bulk sync processes millions of blocks, so a line per block is unreadable
-- and costs real throughput in the hot loop (it is why the benchmark used to
-- discard sieve's output wholesale). Instead every roll-forward folds its work
-- into these counters — cheap, no I/O — and a line is emitted only once
-- 'heartbeatSeconds' have passed.
data Progress = Progress
  { pgStartedAt :: !Double
  -- ^ Monotonic seconds when the sync began; the basis for @elapsed@.
  , pgReportedAt :: !Double
  -- ^ Monotonic seconds when the last line was emitted. Also the left edge of
  -- the window the reported block rate is computed over.
  , pgBlocks :: !Int
  -- ^ Blocks rolled forward since the start.
  , pgOutputs :: !Int
  -- ^ Matched outputs written since the start.
  , pgSpends :: !Int
  -- ^ Spends recorded since the start.
  , pgBlocksAtReport :: !Int
  -- ^ 'pgBlocks' as of the last emitted line, so the rate is the /recent/ rate
  -- rather than a start-to-now average that hides a slowdown.
  , pgSlotAtReport :: !Word64
  -- ^ Slot reached as of the last emitted line. Drives the ETA, which needs a
  -- /slot/ rate rather than the block rate: the distance left to cover is
  -- measured in slots, and on a chain with empty slots the two differ.
  }

-- | Emit at most one progress line per this many seconds.
heartbeatSeconds :: Double
heartbeatSeconds = 5

newProgress :: IO (IORef Progress)
newProgress = do
  now <- getMonotonicTime
  newIORef (Progress now now 0 0 0 0 0)

-- | Fold one block's work into the counters, emitting a progress line if the
-- heartbeat interval has elapsed. One clock read per block on the common path.
--
-- @target@ is the slot the sync is heading for, when known — @--until@ for a
-- bounded run, the server's tip for a following one — and drives the percentage.
tick :: IORef Progress -> SlotNo -> Maybe SlotNo -> String -> Int -> Int -> IO ()
tick ref slotNo target era outputs spends = do
  now <- getMonotonicTime
  pg <- readIORef ref
  let folded =
        pg
          { pgBlocks = pgBlocks pg + 1
          , pgOutputs = pgOutputs pg + outputs
          , pgSpends = pgSpends pg + spends
          }
  if now - pgReportedAt folded < heartbeatSeconds
    then writeIORef ref folded
    else do
      writeIORef
        ref
        folded
          { pgReportedAt = now
          , pgBlocksAtReport = pgBlocks folded
          , pgSlotAtReport = unSlotNo slotNo
          }
      palette <- paletteFor
      logLine (progressLine palette folded now slotNo target era)

-- | The heartbeat line, e.g.
--
-- > 14:22:07  syncing   32.1%  slot 1,284,213/3,999,989  1,843 blk/s  eta 24m35s  blocks 61,204  outputs 418,337  spends 205,118  elapsed 35s
--
-- and once there is no target left to head for:
--
-- > 14:48:19  at tip    slot 3,999,989  12 blk/s  blocks 1,204,551  outputs 8,418,337  spends 7,205,118  elapsed 26m12s
progressLine :: Palette -> Progress -> Double -> SlotNo -> Maybe SlotNo -> String -> String
progressLine palette pg now slotNo target era =
  case target of
    Just t | unSlotNo t > unSlotNo slotNo -> heading t
    -- No target, or we have caught up with it. A percentage and an ETA are
    -- meaningless here, and printing "100.0%" every 5s while following the tip
    -- reads like a stuck sync.
    _ -> atTip
 where
  -- Labels dimmed, figures left bright: these lines are read by scanning the
  -- numbers. 'pad' runs before any escape, or it pads the escape instead.
  label = paint palette dim

  heading t =
    paint palette cyan "syncing"
      <> "   "
      <> pad 6 (showFFloat (Just 1) (100 * ratio t) "%")
      <> "  "
      <> paint palette magenta era
      <> label "  slot "
      <> commas (unSlotNo slotNo)
      <> "/"
      <> commas (unSlotNo t)
      <> "  "
      <> commas (round rate :: Word64)
      <> label " blk/s  eta "
      <> eta t
      <> counters

  atTip =
    paint palette green "at tip"
      <> "    "
      <> paint palette magenta era
      <> label "  slot "
      <> commas (unSlotNo slotNo)
      <> "  "
      <> commas (round rate :: Word64)
      <> label " blk/s"
      <> counters

  counters =
    label "  blocks "
      <> commas (pgBlocks pg)
      <> label "  outputs "
      <> commas (pgOutputs pg)
      <> label "  spends "
      <> commas (pgSpends pg)
      <> label "  elapsed "
      <> duration (now - pgStartedAt pg)

  ratio t = fromIntegral (unSlotNo slotNo) / fromIntegral (unSlotNo t) :: Double

  -- Slots per second over the heartbeat window, not blocks: the remaining
  -- distance is measured in slots, and on a chain with empty slots the two rates
  -- differ by whatever fraction of slots carry a block.
  eta t
    | slotRate <= 0 = "?"
    | otherwise = duration (fromIntegral (unSlotNo t - unSlotNo slotNo) / slotRate)

  slotRate = fromIntegral (unSlotNo slotNo - pgSlotAtReport pg) / window :: Double

  -- Guard the divisor: two blocks can share a clock reading.
  window = max 1e-6 (now - pgReportedAt pg)
  rate = fromIntegral (pgBlocks pg - pgBlocksAtReport pg) / window :: Double

-- | The closing line when a bounded sync finishes.
summarise :: IORef Progress -> IO ()
summarise ref = do
  now <- getMonotonicTime
  pg <- readIORef ref
  let secs = max 1e-6 (now - pgStartedAt pg)
  logStage
    ( "sync done  blocks "
        <> commas (pgBlocks pg)
        <> "  outputs "
        <> commas (pgOutputs pg)
        <> "  spends "
        <> commas (pgSpends pg)
        <> "  elapsed "
        <> duration secs
        <> "  avg "
        <> commas (round (fromIntegral (pgBlocks pg) / secs) :: Word64)
        <> " blk/s"
    )

-- | Emit one log line, prefixed with the wall-clock time.
--
-- A bulk sync runs for tens of minutes and its output is usually read after the
-- fact, out of a redirected file, so \"when did it slow down\" needs an absolute
-- time rather than a relative elapsed figure. Local time, second resolution:
-- enough to line an event up against @cardano-node@'s own log without being
-- noise.
logLine :: String -> IO ()
logLine = emit Nothing

-- | A change of stage: sync starting, tip reached, indexes finished. These are
-- the lines worth scrolling back to; the heartbeat is what lies between them.
logStage :: String -> IO ()
logStage = emit (Just stage)

-- | A warning, or a fallback being taken.
logWarn :: String -> IO ()
logWarn = emit (Just yellow)

-- | Timestamp, two spaces, message. The timestamp is dimmed — it is on every
-- line, so it is the part that should recede.
emit :: Maybe Code -> String -> IO ()
emit code msg = do
  palette <- paletteFor
  now <- getCurrentTime
  tz <- getCurrentTimeZone
  let stamp = formatTime defaultTimeLocale "%H:%M:%S" (utcToLocalTime tz now)
  putStrLn (paint palette dim stamp <> "  " <> maybe id (paint palette) code msg)

-- | An SGR parameter string: @1;36@ is bold cyan.
type Code = String

dim, cyan, green, yellow, magenta, stage :: Code
dim = "2"
cyan = "36"
green = "32"
yellow = "33"
magenta = "35"
stage = "1;36"

-- | Whether this run may put ANSI escapes in its log output.
newtype Palette = Palette Bool

-- | Colour when stdout is a terminal. @NO_COLOR@ set to anything disables it
-- (<https://no-color.org>); @SIEVE_COLOR=always|never@ decides outright, and
-- @always@ is for a piped stdout that a terminal is reading anyway.
--
-- Asked per line, not cached: three syscalls beside the 'getCurrentTimeZone'
-- this module already does per line, once every 'heartbeatSeconds'.
paletteFor :: IO Palette
paletteFor = do
  forced <- lookupEnv "SIEVE_COLOR"
  suppressed <- lookupEnv "NO_COLOR"
  tty <- hIsTerminalDevice stdout
  pure . Palette $ case forced of
    Just "always" -> True
    Just "never" -> False
    _ -> tty && isNothing suppressed

-- | Wrap a string in an SGR code, or leave it alone when colour is off. Written
-- out rather than taken from @ansi-terminal@: four codes and a reset is the
-- whole vocabulary here.
paint :: Palette -> Code -> String -> String
paint (Palette False) _ s = s
paint (Palette True) code s = "\ESC[" <> code <> "m" <> s <> "\ESC[0m"

-- | Seconds as a compact human duration: @45s@, @6m12s@, @2h04m@.
duration :: Double -> String
duration secs
  | secs < 60 = show s <> "s"
  | secs < 3600 = show m <> "m" <> pad0 (s - m * 60) <> "s"
  | otherwise = show h <> "h" <> pad0 (m - h * 60) <> "m"
 where
  s = max 0 (round secs) :: Int
  m = s `div` 60
  h = m `div` 60
  pad0 n = if n < 10 then '0' : show n else show n

-- | Thousands separators. Seven-figure block and output counts are unreadable
-- without them, and these lines exist to be skimmed.
commas :: Show a => a -> String
commas = reverse . intercalate "," . chunksOf3 . reverse . show
 where
  chunksOf3 [] = []
  chunksOf3 xs = let (a, b) = splitAt 3 xs in a : chunksOf3 b

-- | Left-pad to a fixed width so the percentage column does not jitter.
pad :: Int -> String -> String
pad n s = replicate (n - length s) ' ' <> s
