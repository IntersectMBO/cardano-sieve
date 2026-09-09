{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test suite for @cardano-sieve@.
--
-- Phase 2 covers the pure matcher: for each 'Selector' constructor, an output
-- built from known credentials/assets is checked against 'satisfies'. Fixtures
-- are constructed via @cardano-api@ (so we control the exact 28-byte hashes)
-- rather than hard-coded, and the tricky cases are exercised deliberately:
-- key-vs-script agnostic credential matching, base-vs-enterprise-vs-Byron
-- delegation, and the bootstrap wildcard.
module Main (main) where

import Cardano.Api
  ( Address (ByronAddress)
  , AddressAny (AddressByron)
  , AsType (AsAddressAny, AsAssetName, AsHash, AsPaymentKey, AsScriptHash, AsStakeKey, AsTxId)
  , AssetId (AdaAssetId, AssetId)
  , AssetName
  , Block (ByronBlock)
  , BlockInMode (BlockInMode)
  , CardanoEra (ByronEra)
  , Hash
  , NetworkId (Mainnet)
  , PaymentCredential (PaymentCredentialByKey, PaymentCredentialByScript)
  , PaymentKey
  , PolicyId (PolicyId)
  , Quantity (Quantity)
  , ScriptHash
  , SerialiseAsRawBytes
  , StakeAddress
  , StakeAddressReference (NoStakeAddress, StakeAddressByValue)
  , StakeCredential (StakeCredentialByKey)
  , StakeKey
  , TxId
  , TxIn (TxIn)
  , TxIx (TxIx)
  , Value
  , deserialiseAddress
  , deserialiseFromRawBytes
  , lovelaceToValue
  , makeShelleyAddress
  , makeStakeAddress
  , serialiseAddress
  , serialiseToRawBytes
  , serialiseToRawBytesHexText
  , toAddressAny
  , toByronTxId
  )

import Cardano.Chain.Block qualified as CC
import Cardano.Chain.Common qualified as Byron
import Cardano.Chain.Epoch.File (mainnetEpochSlots)
import Cardano.Chain.UTxO qualified as Utxo
import Cardano.Ledger.Binary (byronProtVer, decodeFullDecoder, slice)
import Cardano.Sieve.Node.Decode
  ( DecodedOutput (..)
  , byronOutputsInTx
  , byronTxSpends
  , datumsAndScriptsInBlock
  , encodeOutputRef
  , outputsInBlock
  , spentInputs
  , toContext
  )
import Cardano.Sieve.Node.Encode (toStored)
import Cardano.Sieve.Node.Insert
  ( DatumsAndScripts (dsDatums, dsScripts)
  , DbHandle (dbConn)
  , DirtyDatabase
  , Durability (Durable, UnsafeBulk)
  , PolicyIndexing (DeferPolicies, MaintainPolicies)
  , RedeemerCapture (CaptureRedeemers)
  , SelectorMismatch
  , SpentInput (..)
  , StoredOutput (..)
  , applyBlock
  , buildPolicyIndex
  , closeDatabase
  , openDatabase
  , reconcileSelectors
  , rollbackAbove
  , sampleCheckpoints
  )
import Cardano.Sieve.Selector
  ( BootstrapFilter (IncludeBootstrap, OnlyShelley)
  , CredentialHash
  , OutputContext (..)
  , Selector (..)
  , SelectorParseError (..)
  , credentialHashFromBytes
  , delegationHash
  , paymentHash
  , satisfies
  , selectorFromText
  , selectorToText
  )
import Cardano.Sieve.Server.Api.Matches (Cursor (..), cursorFromText, cursorToText)
import Cardano.Sieve.Value (decodeValue, encodeValue)
import Ouroboros.Consensus.Byron.Ledger (mkByronBlock)

import Codec.Compression.GZip qualified as GZip
import Control.Exception (bracket, bracket_, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Database.SQLite.Simple (Connection, Only (Only), Query, execute_, query_, withConnection)
import GHC.Exts (fromList)
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))

import Test.Gen.Cardano.Api.Typed
  ( genAddressByron
  , genAddressShelley
  , genAssetName
  , genPolicyId
  , genTxId
  , genTxIn
  )

import Hedgehog (Gen, Property, failure, forAll, property, success, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "cardano-sieve"
    [ selectorTests
    , matcherTests
    , parserTests
    , parserPropertyTests
    , matcherPropertyTests
    , rollbackTests
    , selectorPersistenceTests
    , checkpointTests
    , durabilityTests
    , policyIndexTests
    , cursorTests
    , valueTests
    , byronDecodeTests
    , byronGoldenBlockTests
    ]

-- ----------------------------------------------------------------------------
-- Value codec
-- ----------------------------------------------------------------------------

valueTests :: TestTree
valueTests =
  testGroup
    "Value codec"
    [ testProperty "decodeValue . encodeValue roundtrips" prop_valueRoundTrip
    ]

-- | Encoding a value and decoding it back must recover the same ada amount and
-- asset list. Duplicate (policy, name) entries are summed, mirroring what
-- 'encodeValue' does internally.
prop_valueRoundTrip :: Property
prop_valueRoundTrip = property $ do
  lovelace <- forAll (Gen.integral (Range.linear 0 (10 ^ (15 :: Int) :: Integer)))
  entries <-
    forAll $
      Gen.list (Range.linear 0 5) $
        (,,) <$> genPolicyId <*> genAssetName <*> Gen.integral (Range.linear 1 (10 ^ (9 :: Int) :: Integer))
  let v =
        fromList $
          (AdaAssetId, Quantity lovelace)
            : [(AssetId pid name, Quantity q) | (pid, name, q) <- entries]
      grouped =
        Map.fromListWith
          (+)
          [((serialiseToRawBytes pid, serialiseToRawBytes name), q) | (pid, name, q) <- entries]
      expectedAssets =
        sortOn
          (\(p, n, _) -> (p, n))
          [(p, n, q) | ((p, n), q) <- Map.toList grouped]
  decodeValue (encodeValue v) === Right (lovelace, expectedAssets)

-- ----------------------------------------------------------------------------
-- Pagination cursor
-- ----------------------------------------------------------------------------

-- | The opaque page cursor must survive its round trip exactly — a cursor that
-- drifts by one row silently drops or repeats matches at every page boundary —
-- and must reject anything it did not itself produce.
cursorTests :: TestTree
cursorTests =
  testGroup
    "pagination cursor"
    [ testProperty "round-trips through its wire form" $
        property $ do
          desc <- forAll Gen.bool
          slot <- forAll (Gen.int64 (Range.linear 0 maxBound))
          rowid <- forAll (Gen.int64 (Range.linear 0 maxBound))
          let c = Cursor desc slot rowid
          cursorFromText (cursorToText c) === Just c
    , testCase "rejects garbage, truncation, and a foreign direction byte" $ do
        cursorFromText "not-a-cursor" @?= Nothing
        cursorFromText "" @?= Nothing
        -- One byte short of the 17 the codec promises.
        cursorFromText (T.dropEnd 2 (cursorToText (Cursor True 5 7))) @?= Nothing
        -- Right length, direction byte neither 0 nor 1.
        cursorFromText ("02" <> T.drop 2 (cursorToText (Cursor True 5 7))) @?= Nothing
    ]

-- ----------------------------------------------------------------------------
-- Deferred policy index
-- ----------------------------------------------------------------------------

-- | The bulk derive must store exactly what per-row maintenance stores — same
-- (output, policy, asset) rows, reached through the dictionary. Surrogate
-- numbers may differ between the two (assignment order is first-seen versus
-- DISTINCT), so equivalence is judged on resolved triples, never on policy_num.
policyIndexTests :: TestTree
policyIndexTests =
  testGroup
    "deferred policy index"
    [ testCase "the bulk derive stores what per-row maintenance stores" $ do
        maintained <- withTempDb "pol-maintain" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (hash 1) [assetOutput refA] [] mempty
            applyBlock db MaintainPolicies 200 (hash 2) [adaOutput refB] [] mempty
          resolvedTriples path
        derived <- withTempDb "pol-defer" $ \path -> do
          withDb path $ \db -> do
            applyBlock db DeferPolicies 100 (hash 1) [assetOutput refA] [] mempty
            applyBlock db DeferPolicies 200 (hash 2) [adaOutput refB] [] mempty
            buildPolicyIndex db
          resolvedTriples path
        derived @?= maintained
        length derived @?= 1
    , testCase "the derive completes a partially maintained index" $
        withTempDb "pol-gap" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (hash 1) [assetOutput refA] [] mempty
            applyBlock db DeferPolicies 200 (hash 2) [assetOutput refB] [] mempty
            buildPolicyIndex db
          triples <- resolvedTriples path
          length triples @?= 2
    , testCase "re-deriving a complete index changes nothing" $
        withTempDb "pol-idem" $ \path -> do
          withDb path $ \db -> do
            applyBlock db DeferPolicies 100 (hash 1) [assetOutput refA] [] mempty
            buildPolicyIndex db
            buildPolicyIndex db
          triples <- resolvedTriples path
          length triples @?= 1
    ]
 where
  refA = BS.replicate 32 6 <> BS.replicate 8 0
  refB = BS.replicate 32 7 <> BS.replicate 8 0
  hash n = BS.replicate 32 n

  -- One output carrying an asset (its value round-trips through encodeValue,
  -- which is what the derive decodes) and one carrying only ada.
  assetOutput ref = (storedOutput ref){soValue = encodeValue assetValue, soAssets = assetsOfValue}
  adaOutput ref = (storedOutput ref){soValue = encodeValue (fromList [])}
  assetsOfValue =
    [(serialiseToRawBytes policyId, serialiseToRawBytes assetName)]

  withDb path = bracket (openDatabase Durable path 1) closeDatabase

  resolvedTriples :: FilePath -> IO [(ByteString, ByteString, ByteString)]
  resolvedTriples path = withConnection path $ \conn ->
    query_
      conn
      "SELECT o.output_reference, i.policy_id, p.asset_name \
      \FROM policies p \
      \JOIN policy_ids i USING (policy_num) \
      \JOIN outputs o USING (output_num) \
      \ORDER BY o.output_reference, i.policy_id, p.asset_name"

-- ----------------------------------------------------------------------------
-- Bulk durability flag
-- ----------------------------------------------------------------------------

-- | Bulk sessions run with SQLite journaling off, so a crash can corrupt the
-- file undetectably. The only protection is the dirty flag: set for the whole
-- bulk session, cleared on clean close, refused at open ever after.
durabilityTests :: TestTree
durabilityTests =
  testGroup
    "bulk durability flag"
    [ testCase "a bulk session is flagged dirty while open, and clean again after" $
        withTempDb "dirty-lifecycle" $ \path -> do
          db <- openDatabase UnsafeBulk path 1
          flagged <- withConnection path $ \c -> query_ c "PRAGMA user_version"
          flagged @?= [Only (1 :: Int)]
          closeDatabase db
          cleared <- withConnection path $ \c -> query_ c "PRAGMA user_version"
          cleared @?= [Only (0 :: Int)]
    , testCase "a durable session never sets the flag" $
        withTempDb "durable-clean" $ \path -> do
          db <- openDatabase Durable path 1
          flagged <- withConnection path $ \c -> query_ c "PRAGMA user_version"
          flagged @?= [Only (0 :: Int)]
          closeDatabase db
    , testCase "a file left dirty is refused, whatever mode asks" $
        withTempDb "dirty-refused" $ \path -> do
          -- A crash cannot be staged from inside bracket, so plant its residue:
          -- the flag a dying bulk session would have left behind.
          db <- openDatabase UnsafeBulk path 1
          closeDatabase db
          withConnection path $ \c -> execute_ c "PRAGMA user_version=1"
          refusedD <- try (openDatabase Durable path 1)
          case refusedD :: Either DirtyDatabase DbHandle of
            Left _ -> pure ()
            Right db' -> closeDatabase db' >> assertFailure "Durable open accepted a dirty file"
          refusedB <- try (openDatabase UnsafeBulk path 1)
          case refusedB :: Either DirtyDatabase DbHandle of
            Left _ -> pure ()
            Right db' -> closeDatabase db' >> assertFailure "UnsafeBulk open accepted a dirty file"
    ]

-- ----------------------------------------------------------------------------
-- Checkpoints
-- ----------------------------------------------------------------------------

-- | Checkpoints are what a restart intersects on. They must follow rollbacks
-- exactly: a checkpoint above the rollback point names a block no longer on our
-- chain, and offering it to the node would resume from a fork.
checkpointTests :: TestTree
checkpointTests =
  testGroup
    "checkpoints"
    [ testCase "an applied block leaves a checkpoint" $
        withTempDb "cp-write" $ \path -> do
          withDb path $ \db ->
            applyBlock db MaintainPolicies 100 (blockHash 100) [storedOutput outputRef] [] mempty
          n <- withConnection path $ \conn -> count conn "SELECT count(*) FROM checkpoints"
          n @?= 1
    , testCase "a rollback drops the checkpoints above it" $
        withTempDb "cp-rollback" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (blockHash 100) [storedOutput outputRef] [] mempty
            applyBlock db MaintainPolicies 200 (blockHash 200) [storedOutput outputRef2] [] mempty
            rollbackAbove db (Just 150)
          (n, top) <- withConnection path $ \conn ->
            (,)
              <$> count conn "SELECT count(*) FROM checkpoints"
              <*> count conn "SELECT COALESCE(max(slot_no), 0) FROM checkpoints"
          (n, top) @?= (1, 100)
    , testCase "resume points come back newest first" $
        withTempDb "cp-order" $ \path -> do
          withDb path $ \db -> do
            mapM_
              ( \sl ->
                  applyBlock db MaintainPolicies sl (blockHash (fromIntegral sl)) [storedOutput outputRef] [] mempty
              )
              [100, 200, 300]
            points <- sampleCheckpoints (dbConn db)
            map fst points @?= [300, 200, 100]
    , testCase "no checkpoints means no resume points" $
        withTempDb "cp-empty" $ \path ->
          withDb path $ \db -> do
            points <- sampleCheckpoints (dbConn db)
            points @?= []
    ]
 where
  outputRef = BS.replicate 32 2 <> BS.replicate 8 0
  outputRef2 = BS.replicate 32 4 <> BS.replicate 8 0
  blockHash n = BS.replicate 32 n
  withDb path = bracket (openDatabase Durable path 1) closeDatabase

-- ----------------------------------------------------------------------------
-- Selector persistence
-- ----------------------------------------------------------------------------

-- | What a database was indexed with is part of what it means. Indexing on with
-- a different set leaves it incomplete for the selectors it claims to serve, in
-- one direction or the other, and nothing says so at query time.
selectorPersistenceTests :: TestTree
selectorPersistenceTests =
  testGroup
    "selector reconciliation"
    [ testCase "an empty database adopts and stores what was configured" $
        withTempDb "sel-first" $ \path ->
          withDb path $ \db -> do
            got <- reconcileSelectors db [payment]
            got @?= [payment]
            again <- reconcileSelectors db [payment]
            again @?= [payment]
    , testCase "configuring nothing adopts what is stored" $
        withTempDb "sel-adopt" $ \path ->
          withDb path $ \db -> do
            _ <- reconcileSelectors db [payment]
            got <- reconcileSelectors db []
            got @?= [payment]
    , testCase "a different selector is refused" $
        withTempDb "sel-conflict" $ \path ->
          withDb path $ \db -> do
            _ <- reconcileSelectors db [payment]
            outcome <- try (reconcileSelectors db [SelectAll IncludeBootstrap])
            case outcome :: Either SelectorMismatch [Selector] of
              Left _ -> pure ()
              Right s -> assertFailure ("expected a mismatch, indexed " <> show s)
    , testCase "order does not count as a difference" $
        withTempDb "sel-order" $ \path ->
          withDb path $ \db -> do
            _ <- reconcileSelectors db [payment, delegation]
            got <- reconcileSelectors db [delegation, payment]
            length got @?= 2
    , testCase "nothing stored and nothing configured means the wildcard" $
        withTempDb "sel-default" $ \path ->
          withDb path $ \db -> do
            got <- reconcileSelectors db []
            got @?= [SelectAll IncludeBootstrap]
    ]
 where
  payment = SelectPayment (fromMaybe (error "bad hash") (credentialHashFromBytes payBytes))
  delegation = SelectDelegation (fromMaybe (error "bad hash") (credentialHashFromBytes stakeBytes))
  withDb path = bracket (openDatabase Durable path 1) closeDatabase

-- ----------------------------------------------------------------------------
-- Rollback
-- ----------------------------------------------------------------------------

-- | The invariant the whole @outputs@\/@unspent@\/@spends@ split rests on: an
-- output is in @unspent@ exactly when it has no @spends@ row. A rollback has to
-- preserve it, which means undoing a spend must put the output back.
unspentInvariant :: Query
unspentInvariant =
  "SELECT count(*) FROM outputs \
  \WHERE output_reference NOT IN (SELECT output_reference FROM spends)"

rollbackTests :: TestTree
rollbackTests =
  testGroup
    "rollback"
    [ testCase "a rolled-back spend returns its output to the unspent set" $
        withTempDb "spend-rollback" $ \path -> do
          withDb path $ \db -> do
            -- Created well below the rollback point, spent above it: the output
            -- itself survives, its spend does not.
            applyBlock db MaintainPolicies 100 (blockHash 100) [storedOutput outputRef] [] mempty
            applyBlock db MaintainPolicies 200 (blockHash 200) [] [spentInput outputRef] mempty
            rollbackAbove db (Just 150)
          (outs, unspent, spends, expected) <- withConnection path $ \conn ->
            (,,,)
              <$> count conn "SELECT count(*) FROM outputs"
              <*> count conn "SELECT count(*) FROM unspent"
              <*> count conn "SELECT count(*) FROM spends"
              <*> count conn unspentInvariant
          (outs, spends) @?= (1, 0)
          expected @?= 1
          unspent @?= expected
    , testCase "rolling back below an output's creation removes it entirely" $
        withTempDb "create-rollback" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (blockHash 100) [storedOutput outputRef] [] mempty
            applyBlock db MaintainPolicies 200 (blockHash 200) [] [spentInput outputRef] mempty
            rollbackAbove db (Just 50)
          (outs, unspent, spends) <- withConnection path $ \conn ->
            (,,)
              <$> count conn "SELECT count(*) FROM outputs"
              <*> count conn "SELECT count(*) FROM unspent"
              <*> count conn "SELECT count(*) FROM spends"
          (outs, unspent, spends) @?= (0, 0, 0)
    , -- The ordering trap: this output must vanish, not be restored. Restoring
      -- unconditionally and then deleting by created_slot happens to work; doing
      -- it the other way round reinstates a row that should be gone. The
      -- created_slot guard in rollbackAbove is what removes the dependency on
      -- which order those two statements are written in.
      testCase "an output created and spent above the point is removed, not restored" $
        withTempDb "created-and-spent-above" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 160 (blockHash 160) [storedOutput outputRef] [] mempty
            applyBlock db MaintainPolicies 200 (blockHash 200) [] [spentInput outputRef] mempty
            rollbackAbove db (Just 150)
          (outs, unspent, spends, expected) <- withConnection path $ \conn ->
            (,,,)
              <$> count conn "SELECT count(*) FROM outputs"
              <*> count conn "SELECT count(*) FROM unspent"
              <*> count conn "SELECT count(*) FROM spends"
              <*> count conn unspentInvariant
          (outs, unspent, spends) @?= (0, 0, 0)
          unspent @?= expected
    , -- The schema's own words: blocks holds "one row per block that produced a
      -- matched output OR A SPEND". A block that only spends must still leave
      -- one, or its spends render spent_at.header_hash as null.
      testCase "a spend-only block still records its header hash" $
        withTempDb "spend-only-block" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (blockHash 1) [storedOutput outputRef] [] mempty
            applyBlock db MaintainPolicies 200 (blockHash 2) [] [spentInput outputRef] mempty
          n <- withConnection path $ \conn ->
            count conn "SELECT count(*) FROM blocks WHERE slot_no = 200"
          n @?= 1
    , testCase "an unspent output is untouched by a later rollback" $
        withTempDb "untouched" $ \path -> do
          withDb path $ \db -> do
            applyBlock db MaintainPolicies 100 (blockHash 100) [storedOutput outputRef] [] mempty
            rollbackAbove db (Just 150)
          (unspent, expected) <- withConnection path $ \conn ->
            (,)
              <$> count conn "SELECT count(*) FROM unspent"
              <*> count conn unspentInvariant
          unspent @?= expected
          unspent @?= 1
    ]
 where
  outputRef = BS.replicate 32 2 <> BS.replicate 8 0
  blockHash n = BS.replicate 32 n

  withDb path = bracket (openDatabase Durable path 1) closeDatabase

-- | Run an action against a fresh sieve database in a temporary file.
--
-- A file rather than @:memory:@ so the assertions can reopen it on a separate
-- connection once the writer has closed and committed — which also means the
-- test checks what actually reached disk, not just what the open handle thinks.
withTempDb :: String -> (FilePath -> IO a) -> IO a
withTempDb label act = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("cardano-sieve-test-" <> label <> ".sqlite")
      -- WAL mode leaves sidecars behind; clear them too, before and after, so a
      -- crashed previous run cannot leak state into this one.
      scrub = mapM_ rmIfPresent [path, path <> "-wal", path <> "-shm"]
      rmIfPresent p = doesFileExist p >>= \yes -> when yes (removeFile p)
  bracket_ scrub scrub (act path)

count :: Connection -> Query -> IO Int
count conn q = do
  rows <- query_ conn q
  pure (case rows of Only n : _ -> n; [] -> 0)

-- | A minimal stored output. 'soValue' is opaque to the writer (only 'soAssets'
-- feeds the policies table), so arbitrary bytes serve.
storedOutput :: ByteString -> StoredOutput
storedOutput ref =
  StoredOutput
    { soOutputRef = ref
    , soTransactionIndex = 0
    , soAddress = BS.replicate 29 1
    , soPayCred = Just payBytes
    , soDelegCred = Nothing
    , soValue = BS.replicate 4 7
    , soDatumHash = Nothing
    , soDatumType = Nothing
    , soReferenceScriptHash = Nothing
    , soAssets = []
    }

spentInput :: ByteString -> SpentInput
spentInput ref =
  SpentInput
    { siConsumed = ref
    , siSpendingTxId = BS.replicate 32 3
    , siInputIndex = 0
    , siRedeemer = Nothing
    }

-- ----------------------------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------------------------

-- | Deserialise from raw bytes, exploding on failure (fine in test fixtures).
raw :: SerialiseAsRawBytes a => AsType a -> ByteString -> a
raw t = either (error . show) id . deserialiseFromRawBytes t

-- Distinct 28-byte credential hashes and a 32-byte transaction id.
payBytes, stakeBytes, otherBytes, policyBytes :: ByteString
payBytes = BS.replicate 28 11
stakeBytes = BS.replicate 28 22
otherBytes = BS.replicate 28 99
policyBytes = BS.replicate 28 55

payKeyHash :: Hash PaymentKey
payKeyHash = raw (AsHash AsPaymentKey) payBytes

-- | A /script/ hash sharing the same 28 bytes as 'payKeyHash', to prove the
-- match is agnostic to the key-vs-script kind.
payScriptHash :: ScriptHash
payScriptHash = raw AsScriptHash payBytes

stakeKeyHash :: Hash StakeKey
stakeKeyHash = raw (AsHash AsStakeKey) stakeBytes

-- | Base address: payment key hash + stake key hash.
baseAddr :: AddressAny
baseAddr =
  toAddressAny $
    makeShelleyAddress
      Mainnet
      (PaymentCredentialByKey payKeyHash)
      (StakeAddressByValue (StakeCredentialByKey stakeKeyHash))

-- | Enterprise address: payment part only, no delegation.
enterpriseAddr :: AddressAny
enterpriseAddr =
  toAddressAny $
    makeShelleyAddress Mainnet (PaymentCredentialByKey payKeyHash) NoStakeAddress

-- | Enterprise address whose payment part is a /script/ credential with the
-- same hash bytes as 'baseAddr'/'enterpriseAddr'.
scriptPayAddr :: AddressAny
scriptPayAddr =
  toAddressAny $
    makeShelleyAddress Mainnet (PaymentCredentialByScript payScriptHash) NoStakeAddress

-- | A bech32 stake address carrying 'stakeKeyHash'; parsing it selects the
-- delegation part.
stakeAddr :: StakeAddress
stakeAddr = makeStakeAddress Mainnet (StakeCredentialByKey stakeKeyHash)

-- | A real mainnet Byron (bootstrap) address; constructing one programmatically
-- is awkward, so we parse a known-valid one.
byronAddr :: AddressAny
byronAddr =
  fromMaybe (error "byron fixture failed to parse") $
    deserialiseAddress AsAddressAny byronText

byronText :: Text
byronText = "Ae2tdPwUPEZ4YjgvykNpoFeYUxoyhNj2kg8KfKWN2FizsSpLUPv68MpTVDo"

payCH, stakeCH, otherCH :: CredentialHash
payCH = mkCH payBytes
stakeCH = mkCH stakeBytes
otherCH = mkCH otherBytes

mkCH :: ByteString -> CredentialHash
mkCH bs = fromMaybe (error "bad credential-hash fixture") (credentialHashFromBytes bs)

txid, otherTxid :: TxId
txid = raw AsTxId (BS.replicate 32 33)
otherTxid = raw AsTxId (BS.replicate 32 44)

outRef0 :: TxIn
outRef0 = TxIn txid (TxIx 0)

policyId :: PolicyId
policyId = PolicyId (raw AsScriptHash policyBytes)

assetName, otherAssetName :: AssetName
assetName = raw AsAssetName (BS.pack [84, 79, 75]) -- "TOK"
otherAssetName = raw AsAssetName (BS.pack [88]) -- "X"

assetValue :: Value
assetValue = fromList [(AssetId policyId assetName, 5)]

-- | An output context at a given address, empty value and no metadata tags.
ctxAt :: AddressAny -> OutputContext
ctxAt addr =
  OutputContext
    { ocOutputRef = outRef0
    , ocAddress = addr
    , ocValue = mempty
    , ocMetadataTags = Set.empty
    }

-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------

selectorTests :: TestTree
selectorTests =
  testGroup
    "Selector"
    [ testCase "SelectAll equality distinguishes the bootstrap filter" $ do
        (SelectAll IncludeBootstrap == SelectAll IncludeBootstrap) @?= True
        (SelectAll IncludeBootstrap == SelectAll OnlyShelley) @?= False
    ]

matcherTests :: TestTree
matcherTests =
  testGroup
    "Selector.satisfies"
    [ testCase "SelectExact matches only the exact address" $ do
        satisfies (ctxAt baseAddr) (SelectExact baseAddr) @?= True
        satisfies (ctxAt baseAddr) (SelectExact enterpriseAddr) @?= False
    , testCase "SelectPayment matches base, enterprise, and script (key/script agnostic)" $ do
        satisfies (ctxAt baseAddr) (SelectPayment payCH) @?= True
        satisfies (ctxAt enterpriseAddr) (SelectPayment payCH) @?= True
        satisfies (ctxAt scriptPayAddr) (SelectPayment payCH) @?= True
        satisfies (ctxAt baseAddr) (SelectPayment otherCH) @?= False
        satisfies (ctxAt byronAddr) (SelectPayment payCH) @?= False
    , testCase "SelectDelegation matches only base addresses' stake part" $ do
        satisfies (ctxAt baseAddr) (SelectDelegation stakeCH) @?= True
        satisfies (ctxAt baseAddr) (SelectDelegation otherCH) @?= False
        satisfies (ctxAt enterpriseAddr) (SelectDelegation stakeCH) @?= False
        satisfies (ctxAt byronAddr) (SelectDelegation stakeCH) @?= False
    , testCase "SelectPaymentAndDelegation needs both parts to match" $ do
        satisfies (ctxAt baseAddr) (SelectPaymentAndDelegation payCH stakeCH) @?= True
        satisfies (ctxAt baseAddr) (SelectPaymentAndDelegation payCH otherCH) @?= False
        satisfies (ctxAt baseAddr) (SelectPaymentAndDelegation otherCH stakeCH) @?= False
        satisfies (ctxAt enterpriseAddr) (SelectPaymentAndDelegation payCH stakeCH) @?= False
    , testCase "SelectTransactionId matches the producing transaction" $ do
        satisfies (ctxAt baseAddr) (SelectTransactionId txid) @?= True
        satisfies (ctxAt baseAddr) (SelectTransactionId otherTxid) @?= False
    , testCase "SelectOutputReference matches the exact output" $ do
        satisfies (ctxAt baseAddr) (SelectOutputReference outRef0) @?= True
        satisfies (ctxAt baseAddr) (SelectOutputReference (TxIn txid (TxIx 1))) @?= False
    , testCase "SelectPolicyId matches an output carrying the policy" $ do
        satisfies (ctxAt enterpriseAddr){ocValue = assetValue} (SelectPolicyId policyId) @?= True
        satisfies (ctxAt enterpriseAddr) (SelectPolicyId policyId) @?= False
    , testCase "SelectAssetId matches an output carrying the exact asset" $ do
        satisfies (ctxAt enterpriseAddr){ocValue = assetValue} (SelectAssetId policyId assetName) @?= True
        satisfies (ctxAt enterpriseAddr){ocValue = assetValue} (SelectAssetId policyId otherAssetName)
          @?= False
        satisfies (ctxAt enterpriseAddr) (SelectAssetId policyId assetName) @?= False
    , testCase "SelectMetadataTag matches a tag on the producing transaction" $ do
        let ctxM = (ctxAt enterpriseAddr){ocMetadataTags = Set.fromList [674, 721]}
        satisfies ctxM (SelectMetadataTag 674) @?= True
        satisfies ctxM (SelectMetadataTag 999) @?= False
        satisfies (ctxAt enterpriseAddr) (SelectMetadataTag 674) @?= False
    , testCase "SelectAll IncludeBootstrap matches every address (Byron included)" $ do
        satisfies (ctxAt baseAddr) (SelectAll IncludeBootstrap) @?= True
        satisfies (ctxAt byronAddr) (SelectAll IncludeBootstrap) @?= True
    , testCase "SelectAll OnlyShelley excludes Byron addresses" $ do
        satisfies (ctxAt baseAddr) (SelectAll OnlyShelley) @?= True
        satisfies (ctxAt byronAddr) (SelectAll OnlyShelley) @?= False
    ]

parserTests :: TestTree
parserTests =
  testGroup
    "Selector.selectorFromText / selectorToText"
    [ testCase "round-trips every constructor via selectorToText" $
        mapM_
          roundTrips
          [ SelectAll IncludeBootstrap
          , SelectAll OnlyShelley
          , SelectExact baseAddr
          , SelectExact byronAddr
          , SelectPayment payCH
          , SelectDelegation stakeCH
          , SelectPaymentAndDelegation payCH stakeCH
          , SelectTransactionId txid
          , SelectOutputReference outRef0
          , SelectPolicyId policyId
          , SelectAssetId policyId assetName
          , SelectMetadataTag 674
          ]
    , testCase "parses the wildcard forms" $ do
        selectorFromText "*" @?= Right (SelectAll IncludeBootstrap)
        selectorFromText "*/*" @?= Right (SelectAll OnlyShelley)
    , testCase "parses a metadata tag" $
        selectorFromText "{674}" @?= Right (SelectMetadataTag 674)
    , testCase "a bech32 stake address selects its delegation part" $
        selectorFromText (serialiseAddress stakeAddr) @?= Right (SelectDelegation stakeCH)
    , testCase "a base16 address parses as an exact match" $
        selectorFromText (serialiseToRawBytesHexText baseAddr) @?= Right (SelectExact baseAddr)
    , testGroup
        "rejects malformed input with a shape-specific error"
        [ testCase "shapeless bare token is a bad address" $
            selectorFromText "hello" @?= Left (BadAddress "hello")
        , testCase "too many dots is an unrecognised shape" $
            selectorFromText "a.b.c" @?= Left (UnrecognisedShape "a.b.c")
        , testCase "a malformed credential" $
            selectorFromText "zz/*" @?= Left (BadCredential "zz")
        , testCase "a non-numeric metadata tag" $
            selectorFromText "{nope}" @?= Left (BadMetadataTag "nope")
        , testCase "a valid policy with a malformed asset name" $
            selectorFromText (serialiseToRawBytesHexText policyId <> ".zz")
              @?= Left (BadAssetName "zz")
        ]
    ]
 where
  roundTrips s = selectorFromText (selectorToText s) @?= Right s

-- ----------------------------------------------------------------------------
-- Property tests
-- ----------------------------------------------------------------------------

parserPropertyTests :: TestTree
parserPropertyTests =
  testGroup
    "Selector properties"
    [ testProperty "selectorFromText . selectorToText == Right" prop_selectorRoundTrip
    ]

-- | Rendering a selector and parsing it back yields the same selector, across
-- the generated space of every constructor.
prop_selectorRoundTrip :: Property
prop_selectorRoundTrip = property $ do
  s <- forAll genSelector
  selectorFromText (selectorToText s) === Right s

genSelector :: Gen Selector
genSelector =
  Gen.choice
    [ SelectAll <$> Gen.element [IncludeBootstrap, OnlyShelley]
    , SelectExact <$> genAddressAny
    , SelectPayment <$> genCredentialHash
    , SelectDelegation <$> genCredentialHash
    , SelectPaymentAndDelegation <$> genCredentialHash <*> genCredentialHash
    , SelectTransactionId <$> genTxId
    , SelectOutputReference <$> genTxIn
    , SelectPolicyId <$> genPolicyId
    , SelectAssetId <$> genPolicyId <*> genAssetName
    , SelectMetadataTag <$> Gen.word64 Range.constantBounded
    ]

genAddressAny :: Gen AddressAny
genAddressAny =
  Gen.choice
    [ toAddressAny <$> genAddressByron
    , toAddressAny <$> genAddressShelley
    ]

genCredentialHash :: Gen CredentialHash
genCredentialHash =
  fromMaybe (error "genCredentialHash: not 28 bytes")
    . credentialHashFromBytes
    <$> Gen.bytes (Range.singleton 28)

matcherPropertyTests :: TestTree
matcherPropertyTests =
  testGroup
    "Selector.satisfies properties"
    [ testProperty "SelectAll IncludeBootstrap matches any address" prop_wildcardMatchesEverything
    , testProperty "SelectExact matches itself" prop_selectExactMatchesSelf
    , testProperty "SelectExact discriminates distinct addresses" prop_selectExactDiscriminates
    , testProperty
        "SelectPayment matches an address's own payment part"
        prop_selectPaymentMatchesPaymentPart
    , testProperty
        "SelectDelegation matches an address's delegation part when present"
        prop_selectDelegationMatches
    ]

prop_wildcardMatchesEverything :: Property
prop_wildcardMatchesEverything = property $ do
  a <- forAll genAddressAny
  satisfies (ctxAt a) (SelectAll IncludeBootstrap) === True

prop_selectExactMatchesSelf :: Property
prop_selectExactMatchesSelf = property $ do
  a <- forAll genAddressAny
  satisfies (ctxAt a) (SelectExact a) === True

prop_selectExactDiscriminates :: Property
prop_selectExactDiscriminates = property $ do
  a <- forAll genAddressAny
  b <- forAll genAddressAny
  if a == b
    then success
    else satisfies (ctxAt a) (SelectExact b) === False

-- Every Shelley address has a payment credential, so a 'SelectPayment' built
-- from that address's own payment part must match it.
prop_selectPaymentMatchesPaymentPart :: Property
prop_selectPaymentMatchesPaymentPart = property $ do
  a <- forAll (toAddressAny <$> genAddressShelley)
  case credentialHashFromBytes =<< paymentHash a of
    Nothing -> failure
    Just ch -> satisfies (ctxAt a) (SelectPayment ch) === True

-- Only base addresses carry a delegation part by value; when one is present, a
-- 'SelectDelegation' built from it must match. Enterprise/pointer addresses have
-- none, so the law is vacuous there.
prop_selectDelegationMatches :: Property
prop_selectDelegationMatches = property $ do
  a <- forAll (toAddressAny <$> genAddressShelley)
  case credentialHashFromBytes =<< delegationHash a of
    Nothing -> success
    Just ch -> satisfies (ctxAt a) (SelectDelegation ch) === True

-- ----------------------------------------------------------------------------
-- Byron decode
-- ----------------------------------------------------------------------------

-- | The Byron arm of the decoder, one transaction at a time.
byronDecodeTests :: TestTree
byronDecodeTests =
  testGroup
    "Byron decode"
    [ testCase "outputs carry the address, an ada-only value and their index" $ do
        case byronOutputsInTx 7 (byronTx [byronRootIn] [1000000, 2500000]) of
          [o0, o1] -> do
            serialiseAddress (doAddress o0) @?= byronText
            doValue o0 @?= lovelaceToValue 1000000
            doValue o1 @?= lovelaceToValue 2500000
            [ix | DecodedOutput{doOutputRef = TxIn _ (TxIx ix)} <- [o0, o1]] @?= [0, 1]
            map doTransactionIndex [o0, o1] @?= [7, 7]
          outs -> assertFailure ("expected two outputs, got " <> show (length outs))
    , testCase "outputs carry no datum, reference script or metadata tag" $ do
        case byronOutputsInTx 0 (byronTx [byronRootIn] [1000000]) of
          [o] -> do
            doDatum o @?= Nothing
            doReferenceScriptHash o @?= Nothing
            doMetadataTags o @?= Set.empty
          outs -> assertFailure ("expected one output, got " <> show (length outs))
    , testCase "stored form has NULL credentials and no assets" $ do
        case toStored <$> byronOutputsInTx 0 (byronTx [byronRootIn] [1000000]) of
          [row] -> do
            -- NULL credentials are what the query-side bootstrap filter reads.
            soPayCred row @?= Nothing
            soDelegCred row @?= Nothing
            soAssets row @?= []
            soDatumHash row @?= Nothing
            soReferenceScriptHash row @?= Nothing
          rows -> assertFailure ("expected one row, got " <> show (length rows))
    , testCase "the bare wildcard selects a Byron output, `*/*` does not" $ do
        case byronOutputsInTx 0 (byronTx [byronRootIn] [1000000]) of
          [o] -> do
            satisfies (toContext o) (SelectAll IncludeBootstrap) @?= True
            satisfies (toContext o) (SelectAll OnlyShelley) @?= False
          outs -> assertFailure ("expected one output, got " <> show (length outs))
    , testCase "a spend's consumed reference is the produced output's reference" $ do
        let producer = byronTx [byronRootIn] [1000000, 2500000]
        case byronOutputsInTx 0 producer of
          [_o0, o1] -> do
            let TxIn producerId _ = doOutputRef o1
                spender = byronTx [Utxo.TxInUtxo (toByronTxId producerId) 1] [900000]
            case byronTxSpends spender of
              [s] -> do
                siConsumed s @?= encodeOutputRef (doOutputRef o1)
                siSpendingTxId s @?= spendingTxId spender
                siRedeemer s @?= Nothing
              spends -> assertFailure ("expected one spend, got " <> show (length spends))
          outs -> assertFailure ("expected two outputs, got " <> show (length outs))
    , testCase "spends are indexed in the transaction's own input order" $ do
        -- 'otherTxid' sorts after 'txid', so listing it first is an order the
        -- ledger's sorted order would not produce: Byron indexes the
        -- transaction's own order.
        let ins = [Utxo.TxInUtxo (toByronTxId otherTxid) 0, Utxo.TxInUtxo (toByronTxId txid) 0]
        case byronTxSpends (byronTx ins [1000000]) of
          [s0, s1] -> do
            map siInputIndex [s0, s1] @?= [0, 1]
            siConsumed s0 @?= encodeOutputRef (TxIn otherTxid (TxIx 0))
            siConsumed s1 @?= encodeOutputRef (TxIn txid (TxIx 0))
          spends -> assertFailure ("expected two spends, got " <> show (length spends))
    ]

-- | The Byron-ledger address behind the 'byronAddr' fixture.
byronLedgerAddr :: Byron.Address
byronLedgerAddr = case byronAddr of
  AddressByron (ByronAddress a) -> a
  other -> error ("byron fixture is not a Byron address: " <> show other)

-- | A Byron transaction paying the given amounts to 'byronLedgerAddr'.
-- Witnesses are empty; the decode path does not read them.
byronTx :: [Utxo.TxIn] -> [Word64] -> Utxo.ATxAux ByteString
byronTx ins amounts =
  Utxo.annotateTxAux (Utxo.mkTxAux tx mempty)
 where
  tx =
    Utxo.UnsafeTx
      (NE.fromList ins)
      (NE.fromList (mkOut <$> amounts))
      (Byron.mkAttributes ())
  mkOut n = Utxo.TxOut byronLedgerAddr (byronLovelace n)

byronLovelace :: Word64 -> Byron.Lovelace
byronLovelace n = either (error . show) id (Byron.mkLovelace n)

-- | A stand-in input, for when only the transaction's outputs are under test.
byronRootIn :: Utxo.TxIn
byronRootIn = Utxo.TxInUtxo (toByronTxId txid) 0

-- | The id of a Byron transaction, as a spend records it.
spendingTxId :: Utxo.ATxAux ByteString -> ByteString
spendingTxId atx = case byronOutputsInTx 0 atx of
  DecodedOutput{doOutputRef = TxIn i _} : _ -> serialiseToRawBytes i
  [] -> error "transaction has no outputs"

-- ----------------------------------------------------------------------------
-- Byron golden block
-- ----------------------------------------------------------------------------

-- | The Byron path from real block bytes to decoded rows, including the
-- 'BlockInMode' dispatch the per-transaction tests cannot reach.
--
-- Both fixtures are mainnet blocks in the 'CC.ABlockOrBoundary' encoding the
-- node's ImmutableDB stores, from cardano-rpc's golden files: block 2,160,150
-- (epoch 100) with six transactions, and an epoch boundary block. The ids
-- asserted below were verified against mainnet, so the output references are
-- pinned to the chain rather than to this code.
byronGoldenBlockTests :: TestTree
byronGoldenBlockTests =
  testGroup
    "Byron golden block"
    [ testCase "the six transactions' outputs, in block order" $ do
        blk <- goldenBlock
        let outs = outputsInBlock blk
        length outs @?= 17
        -- Grouped by transaction: 2,2,2,2,7,2.
        map doTransactionIndex outs @?= [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 4, 4, 4, 4, 5, 5]
        nubOrder [txIdHex o | o <- outs] @?= goldenTxIds
        [ix | DecodedOutput{doOutputRef = TxIn _ (TxIx ix)} <- outs]
          @?= [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 3, 4, 5, 6, 0, 1]
    , testCase "every output is a bootstrap address with an ada-only value" $ do
        blk <- goldenBlock
        let rows = map toStored (outputsInBlock blk)
        -- Counted, not compared: these records have no Eq.
        length (filter (not . null . soAssets) rows) @?= 0
        length (filter ((/= Nothing) . soPayCred) rows) @?= 0
        length (filter ((/= Nothing) . soDelegCred) rows) @?= 0
        length (filter ((/= Nothing) . soDatumHash) rows) @?= 0
        length (filter ((/= Nothing) . soReferenceScriptHash) rows) @?= 0
    , testCase "the spends are the transactions' inputs, in transaction order" $ do
        blk <- goldenBlock
        -- Asking for redeemers must still yield none.
        let spends = spentInputs CaptureRedeemers blk
        length spends @?= 17
        length (filter ((/= Nothing) . siRedeemer) spends) @?= 0
        -- Inputs per transaction: 2,10,2,1,1,1 — the ten-input one is what
        -- makes the order assertion meaningful.
        map siInputIndex spends @?= [0, 1] <> [0 .. 9] <> [0, 1] <> [0] <> [0] <> [0]
    , testCase "a Byron block carries no datums and no scripts" $ do
        blk <- goldenBlock
        let ds = datumsAndScriptsInBlock blk
        dsDatums ds @?= []
        dsScripts ds @?= []
    , testCase "an epoch boundary block contributes nothing" $ do
        blk <- goldenBoundaryBlock
        length (outputsInBlock blk) @?= 0
        length (spentInputs CaptureRedeemers blk) @?= 0
    ]
 where
  txIdHex DecodedOutput{doOutputRef = TxIn i _} = serialiseToRawBytesHexText i
  nubOrder = foldr (\x acc -> x : filter (/= x) acc) []

-- | The golden block's transaction ids, in block order.
goldenTxIds :: [Text]
goldenTxIds =
  [ "d2937ec5576f63094d066a3ad93997bf55e651d76b7dc4082a2cef5a85eae657"
  , "649756d9194ecd79b017fa4753748d44da0d231d95b8f2b4a8e44d2cbab529c8"
  , "c6304ae76fe6a0493f5236dee75b42b9ec33cd62782f2db455a36e40143a1d12"
  , "734932fb26bbd9ec29d4f904285e6623e11e7a9751675f761c3b53a04f0c1a68"
  , "c2ae415049dbc046c5650e6ba74e52dd2eef87f31f3712ccc220aa26c51a097a"
  , "e54e392d7ed0f79bdff0342b2588be3eb899ca997364812e31651b4346038b1d"
  ]

goldenBlock :: IO BlockInMode
goldenBlock = byronFixture id "test/files/golden/byron-main-block.cbor"

goldenBoundaryBlock :: IO BlockInMode
goldenBoundaryBlock = byronFixture GZip.decompress "test/files/golden/byron-ebb.cbor.gz"

-- | Decode a Byron block fixture into the 'BlockInMode' a sync would hand the
-- decoder. 'slice' re-attaches the original bytes, which is what makes the
-- transaction ids come out right: they hash a transaction's own bytes.
byronFixture :: (LBS.ByteString -> LBS.ByteString) -> FilePath -> IO BlockInMode
byronFixture unwrap path = do
  bytes <- unwrap <$> LBS.readFile path
  case decodeFullDecoder
    byronProtVer
    "ABlockOrBoundary"
    (CC.decCBORABlockOrBoundary mainnetEpochSlots)
    bytes of
    Left err -> assertFailure ("golden fixture " <> path <> " failed to decode: " <> show err)
    Right blockOrBoundary ->
      pure $
        BlockInMode ByronEra $
          ByronBlock $
            mkByronBlock mainnetEpochSlots (LBS.toStrict . slice bytes <$> blockOrBoundary)
