{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

module Language.Marlowe.Runtime.Indexer.ChainSeekClient
  where

import Cardano.Api (CardanoMode, EraHistory, SystemStart)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Concurrently(..))
import Control.Concurrent.Component
import Control.Concurrent.STM (STM, atomically, newTQueue, readTQueue, writeTQueue)
import Data.List (sortOn)
import Data.Ord (Down(Down))
import Data.Set (Set)
import Data.Set.NonEmpty (NESet)
import qualified Data.Set.NonEmpty as NESet
import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds)
import Data.Void (Void, absurd)
import Language.Marlowe.Runtime.ChainSync.Api
import Language.Marlowe.Runtime.Indexer.Database (DatabaseQueries(..))
import Language.Marlowe.Runtime.Indexer.Types (MarloweBlock(..), MarloweUTxO(..), extractMarloweBlock)
import Network.Protocol.Driver (RunClient)
import Observe.Event (addField, withEvent)
import Observe.Event.Backend (EventBackend)
import Witherable (wither)

data ChainSeekClientSelector f where
  LoadMarloweUTxO :: ChainSeekClientSelector MarloweUTxO

-- | Injectable dependencies for the chain seek client
data ChainSeekClientDependencies r = ChainSeekClientDependencies
  { securityParameter :: Int
  -- ^ The protocol security parameter. The maximum number of blocks that can be rolled back.

  , databaseQueries :: DatabaseQueries IO
  -- ^ Implementations of the database queries.

  , runChainSeekClient :: RunClient IO RuntimeChainSeekClient
  -- ^ A function that runs a client of the chain seek protocol.

  , pollingInterval :: NominalDiffTime
  -- ^ How frequently to poll the chain seek server when waiting.

  , marloweScriptHashes :: NESet ScriptHash
  -- ^ The set of known marlowe script hashes.

  , payoutScriptHashes :: NESet ScriptHash
  -- ^ The set of known payout script hashes.

  , systemStart :: SystemStart
  -- ^ The starting type of the blockchain.

  , eraHistory :: EraHistory CardanoMode
  -- ^ The history of era switches in the blockchain.

  , eventBackend :: EventBackend IO r ChainSeekClientSelector
  }

-- | A change to the chain with respect to Marlowe contracts
data ChainEvent
  -- | A change in which a new block of Marlowe transactions is added to the chain.
  = RollForward MarloweBlock ChainPoint ChainPoint

  -- | A change in which the chain is reverted to a previous point, discarding later blocks.
  | RollBackward ChainPoint ChainPoint

-- | A component that runs a chain seek client to traverse the blockchain and
-- extract blocks of Marlowe transactions. The sequence of changes to the chain
-- can be read by repeatedly running the resulting STM action.
chainSeekClient :: forall r. Component IO (ChainSeekClientDependencies r) (STM ChainEvent)
chainSeekClient = component \ChainSeekClientDependencies{..} -> do
  -- Initialize a TQueue for emitting ChainEvents.
  eventQueue <- newTQueue

  -- Return the component's thread action and the action to pull the next chain
  -- event.
  pure
    -- In this component's thread, run the chain seek client that will pull the
    -- transactions for discovering and following Marlowe contracts
    ( runChainSeekClient $ client
        (atomically . writeTQueue eventQueue)
        databaseQueries
        securityParameter
        pollingInterval
        marloweScriptHashes
        payoutScriptHashes
        systemStart
        eraHistory
        eventBackend
    , readTQueue eventQueue
    )
  where
  -- | A chain seek client that discovers and follows all Marlowe contracts
  client
    :: (ChainEvent -> IO ())
    -> DatabaseQueries IO
    -> Int
    -> NominalDiffTime
    -> NESet ScriptHash
    -> NESet ScriptHash
    -> SystemStart
    -> EraHistory CardanoMode
    -> EventBackend IO r ChainSeekClientSelector
    -> RuntimeChainSeekClient IO ()
  client emit DatabaseQueries{..} securityParameter pollingInterval marloweScriptHashes payoutScriptHashes systemStart eraHistory eventBackend =
    ChainSeekClient $ pure $ SendMsgRequestHandshake moveSchema $ ClientStHandshake
      { recvMsgHandshakeRejected = \_ -> fail "unsupported chain seek version"
      , recvMsgHandshakeConfirmed = do
          -- Get the intersection points - the most recent block headers stored locally.
          intersectionPoints <- getIntersectionPoints
          let
            -- A client state for handling the intersect response.
            clientNextIntersect = ClientStNext
              -- Rejection of an intersection request implies no intersection was found.
              -- In this case, we have no choice but to start synchronization from Genesis.
              { recvMsgQueryRejected = \_ tip -> do
                  -- Roll everything back to Genesis.
                  emit $ RollBackward Genesis tip
                  let
                    -- Initial empty Marlowe UTxO
                    rollbackStates = RollbackStates
                      { currentState = MarloweUTxO mempty mempty
                      , currentBlockNumber = Genesis
                      , previousStates = []
                      }

                  -- Start the main synchronization loop
                  pure $ clientIdle rollbackStates

              -- An intersection point was found, resume synchronization from
              -- that point.
              , recvMsgRollForward = \_ point tip -> do
                  -- Always emit a rollback at the start.
                  emit $ RollBackward point tip
                  let
                    -- The block number of the tip point
                    tipBlockNo = case tip of
                      Genesis -> -1
                      At BlockHeader{..} -> fromIntegral blockNo

                    -- Determines if a block is within the security parameter of
                    -- the tip, and must be retained in case a rollback occurs.
                    isYoungerThanSecurityParameter BlockHeader{blockNo} =
                      tipBlockNo - fromIntegral blockNo <= securityParameter

                    -- List of block headers to load the MarloweUTxO at, in
                    -- descending order, excluding the current block.
                    utxoHistoryRange =
                      -- Only load the Marlowe UTxO for blocks within the range of possible rollbacks.
                      takeWhile isYoungerThanSecurityParameter
                        -- Skip the current block (will be added back later).
                        $ drop 1
                        -- Drop blocks that were newer than the intersection point, as they have been rolled back.
                        $ dropWhile ((> point) . At)
                        -- Sort descending
                        $ sortOn Down intersectionPoints

                  -- Load the MarloweUTxO history in parallel, using ApplicativeDo and Concurrently.
                  rollbackStates <- withEvent eventBackend LoadMarloweUTxO \ev -> runConcurrently do
                    -- Load the current MarloweUTxO (this is why it was skipped in utxoHistoryRange).
                    currentState <- case point of
                      -- If the intersection point is at Genesis, return an empty MarloweUTxO.
                      Genesis -> pure $ MarloweUTxO mempty mempty

                      -- Otherwise load it from the database.
                      At block -> Concurrently $ getMarloweUTxO block >>= \case
                        Nothing -> fail $ "Unable to load MarloweUTxO at unknown block " <> show block
                        Just utxo -> do
                          addField ev utxo
                          pure utxo

                    -- Load the previous MarloweUTxOs in parallel.
                    previousStates <- flip wither utxoHistoryRange \block ->
                      Concurrently $ fmap (At $ blockNo block,) <$> getMarloweUTxO block

                    -- Initialize the rollback states.
                    pure RollbackStates
                      { currentState
                      , currentBlockNumber = blockNo <$> point
                      , previousStates
                      }

                  -- Start the main synchronization loop.
                  pure $ clientIdle rollbackStates

              -- Since the client is at Genesis at the start of this request,
              -- it will never be rolled back. Handle the perfunctory case by
              -- looping.
              , recvMsgRollBackward = \_ _ -> pure clientIdleIntersect

              -- If the client is caught up to the tip, poll for the query results.
              , recvMsgWait = pollWithNext clientNextIntersect
              }

            -- A client state for sending the intersect request.
            clientIdleIntersect = SendMsgQueryNext (Intersect intersectionPoints) clientNextIntersect

          pure case intersectionPoints of
            -- Just start the loop right away with an empty UTxO.
            [] -> clientIdle RollbackStates
              { currentState = MarloweUTxO mempty mempty
              , currentBlockNumber = Genesis
              , previousStates = []
              }
            -- Request an intersection
            _ -> clientIdleIntersect
      }
      where
      allScriptCredentials = NESet.map ScriptCredential $ NESet.union marloweScriptHashes payoutScriptHashes
      -- A helper function to poll pending query results after a set timeout and
      -- continue with the given ClientStNext.
      pollWithNext
        :: ClientStNext Move err res ChainPoint (WithGenesis BlockHeader) IO a
        -> IO (ClientStPoll Move err res ChainPoint (WithGenesis BlockHeader) IO a)
      pollWithNext next = do
        -- Wait for the polling interval to elapse (converted from seconds to
        -- milliseconds).
        threadDelay $ floor $ 1_000_000 * nominalDiffTimeToSeconds pollingInterval

        -- Poll for results and handle the response with the given ClientStNext.
        pure $ SendMsgPoll next

      -- The client's idle state handler for the main synchronization loop.
      -- Sends the next query to the chain seek server and handles the
      -- response.
      clientIdle
        :: RollbackStates MarloweUTxO
        -> ClientStIdle Move ChainPoint (WithGenesis BlockHeader) IO a
      clientIdle = SendMsgQueryNext (FindTxsFor allScriptCredentials) . clientNext

      -- Handles responses from the main synchronization loop query.
      clientNext
        :: RollbackStates MarloweUTxO
        -> ClientStNext Move Void (Set Transaction) ChainPoint (WithGenesis BlockHeader) IO a
      clientNext states = ClientStNext
        -- Fail with an error if chainseekd rejects the query. This is safe
        -- from bad user input, because our queries are derived from the ledger
        -- state, and so will only be rejected if the query derivation is
        -- incorrect, or chainseekd is corrupt. Because both are unexpected
        -- errors, it is a non-recoverable error state.
        { recvMsgQueryRejected = absurd

        -- Handle the next block by extracting Marlowe transactions into a
        -- MarloweBlock and updating the MarloweUTxO.
        , recvMsgRollForward = \txs point tip -> do
            -- Get the current block (not expected ever to be Genesis).
            block <- case point of
              Genesis -> fail "Rolled forward to Genesis"
              At block -> pure block

            -- Get the current remote tip block (not expected ever to be Genesis, because it is expected to be larger than or equal to point).
            tipBlock <- case tip of
              Genesis -> fail "Unexpected tip at Genesis"
              At tipBlock -> pure tipBlock

            -- Extract the Marlowe block and compute the next MarloweUTxO.
            marloweUTxO <- case extractMarloweBlock systemStart eraHistory (NESet.toSet marloweScriptHashes) block txs $ currentState states of
              -- If no MarloweBlock was extracted (not expected, but harmless), do nothing and return the current MarloweUTxO.
              -- This is not expected because the query would only be satisfied by a block that contains some usable Marlowe information.
              Nothing -> pure $ currentState states

              Just (marloweUTxO, marloweBlock) -> do
                -- Emit the marlowe block in a roll forward event to a downstream consumer.
                emit $ RollForward marloweBlock point tip

                -- Return the new MarloweUTxO
                pure marloweUTxO

            -- Loop back into the main synchronization loop with an updated
            -- rollback state.
            pure $ clientIdle $ pushState securityParameter (blockNo block) (blockNo tipBlock) marloweUTxO states

        , recvMsgRollBackward = \point tip -> do
            emit $ RollBackward point tip
            pure $ clientIdle $ rollback (blockNo <$> point) states

        , recvMsgWait = pollWithNext $ clientNext states
        }

-- A current state with a collection of previous states
data RollbackStates a = RollbackStates
  { currentState :: a
  , currentBlockNumber :: WithGenesis BlockNo
  , previousStates :: [(WithGenesis BlockNo, a)]
  }

-- Add a new state at the given block number to the collection, moving the
-- current state to the previous states.
pushState :: Int -> BlockNo -> BlockNo -> a -> RollbackStates a -> RollbackStates a
pushState securityParameter blockNo tip state RollbackStates{..} = RollbackStates
  { currentState = state
  , currentBlockNumber = At blockNo
  -- Add the previous current state to the previous states, and drop any
  -- previous states that are older than the securityParameter (i.e. we can
  -- safely assume we won't roll back to them).
  , previousStates = takeWhile isYoungerThanSecurityParameter $ (currentBlockNumber, currentState) : previousStates
  }
  where
    isYoungerThanSecurityParameter (Genesis, _) = fromIntegral tip <= securityParameter
    isYoungerThanSecurityParameter (At blockNo', _) = fromIntegral (tip - blockNo') <= securityParameter

-- Rollback the state collection to a previous state. Throws an exception if
-- there are no previous states to rollback to.
rollback :: WithGenesis BlockNo -> RollbackStates a -> RollbackStates a
rollback rollbackBlock states@RollbackStates{..}
  | currentBlockNumber <= rollbackBlock = states
  | otherwise = case previousStates of
      [] -> error "No previous states to rollback"
      (currentBlockNumber', currentState') : previousStates' -> rollback rollbackBlock RollbackStates
        { currentState = currentState'
        , currentBlockNumber = currentBlockNumber'
        , previousStates = previousStates'
        }