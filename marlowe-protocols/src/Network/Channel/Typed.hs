{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

module Network.Channel.Typed where

import Control.Monad.Event.Class
  (MonadEvent, composeInjectSelector, withInjectEvent, withInjectEventArgs, withInjectEventFields)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Binary (put)
import Data.Binary.Put (runPut)
import qualified Data.ByteString.Lazy as LBS
import Network.Channel (socketAsChannel)
import Network.Protocol.Codec (BinaryMessage)
import Network.Protocol.Connection (Connection(..), ConnectionSource(..), Connector(..), ToPeer)
import Network.Protocol.Driver.Trace
import Network.Protocol.Peer
import Network.Protocol.Peer.Trace
import Network.Socket
  ( AddrInfo(addrSocketType)
  , HostName
  , PortNumber
  , SocketType(Stream)
  , addrAddress
  , connect
  , defaultHints
  , getAddrInfo
  , openSocket
  )
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString.Lazy as Socket
import Network.TypedProtocol (SomeMessage(..))
import Network.TypedProtocol.Codec (AnyMessageAndAgency(AnyMessageAndAgency))
import Network.TypedProtocol.Core
import Observe.Event
  (InjectSelector, NewEventArgs(newEventParent), addField, injectSelector, newEventInitialFields, reference)
import Observe.Event.Backend (simpleNewEventArgs)
import UnliftIO
  ( MonadIO
  , MonadUnliftIO
  , STM
  , SomeException
  , TQueue
  , atomically
  , catch
  , liftIO
  , newEmptyTMVar
  , newTQueue
  , putTMVar
  , readTMVar
  , readTQueue
  , throwIO
  , withRunInIO
  , writeTQueue
  )
import UnliftIO.Resource (allocate)

-- | A channel can send or receive a protocol message depending on the current
-- protocol state and the peer role.
data Channel ps pr (st :: ps) m = Channel
  { yield :: forall st'. WeHaveAgency pr st -> Message ps st st' -> OutboundChannel ps pr st' m
  -- ^ When we have agency, the channel can send a message. Returns a
  -- record of operations for sending messages.
  , await :: TheyHaveAgency pr st -> m (InboundChannel ps pr st m)
  -- ^ When our peer has agency, the channel can receive a message. Awaits a
  -- message and returns it alongside a record of operations for handling it.
  }

-- | A record of operations available on an outbound message.
data OutboundChannel ps pr (st :: ps) m = OutboundChannel
  { cast :: m (Channel ps pr st m)
  -- ^ Send the message and get the channel for the next state.
  , call :: TheyHaveAgency pr st -> m (ResponseChannel ps pr st m)
  -- ^ Send the message and await a response on an inbound channel.
  , close :: NobodyHasAgency st -> m ()
  -- ^ Send the message and hang up.
  }

-- | A channel for receiving a response to a call.
data ResponseChannel ps pr (st :: ps) m = forall st'. ResponseChannel
  { responseMessage :: Message ps st st'
  -- ^ The message that was received
  , responseChannel :: Channel ps pr st' m
  -- ^ The next channel
  }

-- | A record of operations available for handling a received message.
data InboundChannel ps pr (st :: ps) m = forall st'. InboundChannel
  { message :: Message ps st st'
  -- ^ The message that was received
  , receive :: m (Channel ps pr st' m)
  -- ^ Receive the message and get the next channel.
  , respond :: forall a. WeHaveAgency pr st' -> Handler ps pr st' m a -> m a
  -- ^ Handle the message by sending a response.
  , closed :: NobodyHasAgency st' -> m ()
  -- ^ Hang up.
  }

-- | Wrapper for a function that handles a message by sending a response.
newtype Handler ps pr (st :: ps) m a = Handler
  { withSendResponse
      -- The response callback. Send a response to get the next channel.
      :: (forall st'. (Message ps st st' -> m (Channel ps pr st' m)))
      -> m a
  }

-- | Apply a natural transformation to a channel.
ihoistChannel
  :: forall ps pr st m n
   . Functor m
  => (forall x. m x -> n x)
  -> (forall x. n x -> m x)
  -> Channel ps pr st m
  -> Channel ps pr st n
ihoistChannel f f' = go
  where
    go :: Channel ps pr st' m -> Channel ps pr st' n
    go Channel{..} = Channel
      { yield = \tok msg -> goOutbound $ yield tok msg
      , await = f . fmap goInbound . await
      }

    goOutbound :: OutboundChannel ps pr st' m -> OutboundChannel ps pr st' n
    goOutbound OutboundChannel{..} = OutboundChannel
      { cast = f $ go <$> cast
      , call = f . fmap goResponse . call
      , close = f . close
      }

    goResponse :: ResponseChannel ps pr st' m -> ResponseChannel ps pr st' n
    goResponse ResponseChannel{..} = ResponseChannel
      { responseChannel = go responseChannel
      , ..
      }

    goInbound :: InboundChannel ps pr st' m -> InboundChannel ps pr st' n
    goInbound InboundChannel{..} = InboundChannel
      { respond = \tok' Handler{..} -> f $ respond tok' Handler
          { withSendResponse = \sendResponse -> f' $ withSendResponse \msg' ->
              f $ go <$> sendResponse msg'
          }
      , receive = f $ go <$> receive
      , closed = f . closed
      , ..
      }

-- | Lower a channel from a protocol into a sub-protocol which it embeds.
lowerChannel
  :: forall ps ps' pr (st :: ps) (stLift :: ps -> ps') m
   . Functor m
  => LiftProtocol ps ps' stLift
  -> Channel ps' pr (stLift st) m
  -> Channel ps pr st m
lowerChannel LiftProtocol{..} = go
  where
    go :: Channel ps' pr (stLift st') m -> Channel ps pr st' m
    go Channel{..} = Channel
      { yield = \tok msg -> goOutbound $ yield (liftAgency tok) (liftMessage msg)
      , await = fmap goInbound . await . liftAgency
      }

    goOutbound :: OutboundChannel ps' pr (stLift st') m -> OutboundChannel ps pr st' m
    goOutbound OutboundChannel{..} = OutboundChannel
      { cast = go <$> cast
      , call = fmap goResponse . call . liftAgency
      , close = close . liftNobody
      }

    goResponse :: ResponseChannel ps' pr (stLift st') m -> ResponseChannel ps pr st' m
    goResponse ResponseChannel{..} = case unliftMessage responseMessage of
      SomeSubMessage subMsg -> ResponseChannel
        { responseMessage = subMsg
        , responseChannel = go responseChannel
        }

    goInbound :: InboundChannel ps' pr (stLift st') m -> InboundChannel ps pr st' m
    goInbound InboundChannel{..} = case unliftMessage message of
      SomeSubMessage subMsg -> InboundChannel
        { message = subMsg
        , receive = go <$> receive
        , closed = closed . liftNobody
        , respond = \tok' Handler{..} -> respond (liftAgency tok') Handler
            { withSendResponse = \sendResponse -> withSendResponse \msg' ->
                fmap go $ sendResponse $ liftMessage msg'
            }
        }

    liftAgency :: PeerHasAgency pr' x -> PeerHasAgency pr' (stLift x)
    liftAgency = \case
      ClientAgency tok -> ClientAgency $ liftClient tok
      ServerAgency tok -> ServerAgency $ liftServer tok

-- | Run a peer over a channel.
runPeerOverChannel
  :: forall ps pr st m a
   . Monad m
  => Channel ps pr st m
  -> PeerTraced ps pr st m a
  -> m a
runPeerOverChannel channel@Channel{..} = \case
  EffectTraced m -> runPeerOverChannel channel =<< m
  YieldTraced tok msg peer -> goOutbound (yield tok msg) peer
  AwaitTraced tok k -> goInbound k =<< await tok
  DoneTraced _ a -> pure a
  where
    goOutbound :: OutboundChannel ps pr st' m -> YieldTraced ps pr st' m a -> m a
    goOutbound OutboundChannel{..} = \case
      Cast peer -> do
        channel' <- cast
        runPeerOverChannel channel' peer
      Call tok k -> do
        ResponseChannel{..} <- call tok
        runPeerOverChannel responseChannel $ k responseMessage
      Close tok a -> do
        close tok
        pure a

    goInbound
      :: (forall st''. Message ps st' st'' -> AwaitTraced ps pr st'' m a)
      -> InboundChannel ps pr st' m
      -> m a
    goInbound k InboundChannel{..} = case k message of
      Receive peer -> do
        channel' <- receive
        runPeerOverChannel channel' peer
      Respond tok handle -> respond tok Handler
        { withSendResponse = \sendResponse -> do
            Response msg peer <- handle
            channel' <- sendResponse msg
            runPeerOverChannel channel' peer
        }
      Closed tok ma -> do
        closed tok
        ma

driverToChannel
  :: forall ps pr st dState r s m
   . MonadEvent r s m
  => InjectSelector (TypedProtocolsSelector ps) s
  -> DriverTraced ps dState r m
  -> Channel ps pr st m
driverToChannel inj driver = go $ startDStateTraced driver
  where
    go :: dState -> Channel ps pr st' m
    go dState = Channel
      { yield = goOutbound dState
      , await = goInbound dState
      }

    goOutbound :: dState -> WeHaveAgency pr st' -> Message ps st' st'' -> OutboundChannel ps pr st'' m
    goOutbound dState tok msg = OutboundChannel
      { cast = withInjectEventFields inj (CastSelector tok msg) [()] \ev -> do
          sendMessageTraced driver (reference ev) tok msg
          pure $ go dState
      , call = \tok' -> withInjectEventFields inj (CallSelector tok msg) [()] \ev -> do
          sendMessageTraced driver (reference ev) tok msg
          (_, SomeMessage msg', dState') <- recvMessageTraced driver tok' dState
          pure $ ResponseChannel msg' $ go dState'
      , close = \_ -> withInjectEventFields inj (CloseSelector tok msg) [()] \ev -> do
          sendMessageTraced driver (reference ev) tok msg
      }

    goInbound :: dState -> PeerHasAgency (FlipAgency pr) st' -> m (InboundChannel ps pr st' m)
    goInbound dState tok = do
      (sendRef, SomeMessage message, dState') <- recvMessageTraced driver tok dState
      let
        receiveArgs = (simpleNewEventArgs $ ReceiveSelector tok message)
          { newEventParent = Just sendRef
          , newEventInitialFields = [()]
          }
        respondArgs = (simpleNewEventArgs $ RespondSelector tok message)
          { newEventParent = Just sendRef
          , newEventInitialFields = [()]
          }
        closeArgs = (simpleNewEventArgs $ CloseSelector tok message)
          { newEventParent = Just sendRef
          , newEventInitialFields = [()]
          }
      pure InboundChannel
        { message
        , receive = withInjectEventArgs inj receiveArgs $ const $ pure $ go dState'
        , respond = \tok' Handler{..} ->
            withInjectEventArgs inj respondArgs \ev -> withSendResponse \msg -> do
              sendMessageTraced driver (reference ev) tok' msg
              pure $ go dState'
        , closed = const $ withInjectEventArgs inj closeArgs $ const $ pure ()
        }

tcpClientChannel
  :: (MonadUnliftIO m, MonadEvent r s m, HasSpanContext r, BinaryMessage ps)
  => InjectSelector (TcpClientSelector ps) s
  -> HostName
  -> PortNumber
  -> ResourceT m (Channel ps pr st (ResourceT m), r)
tcpClientChannel inj host port = withInjectEvent inj Connect \ev -> do
  addr <- liftIO $ head <$> getAddrInfo
    (Just defaultHints { addrSocketType = Stream })
    (Just host)
    (Just $ show port)
  addField ev addr
  let closeArgs = (simpleNewEventArgs CloseClient) { newEventParent = Just $ reference ev }
  (_, socket) <- withRunInIO \runInIO ->
    runInIO $ allocate (openSocket addr) $ runInIO . withInjectEventArgs inj closeArgs . const . liftIO . Socket.close
  liftIO $ connect socket $ addrAddress addr
  spanContext <- context $ reference ev
  let spanContextBytes = runPut $ put spanContext
  let spanContextLength = LBS.length spanContextBytes
  liftIO $ Socket.sendAll socket $ runPut $ put spanContextLength
  liftIO $ Socket.sendAll socket spanContextBytes
  _ <- liftIO $ Socket.recv socket 1
  let
    driver = mkDriverTraced
      (composeInjectSelector inj $ injectSelector $ ClientDriver addr)
      (socketAsChannel socket)
  pure
    ( driverToChannel (composeInjectSelector inj $ injectSelector $ ClientPeer addr) driver
    , reference ev
    )

data ClientWithResponseChannel client m where
  ClientWithResponseChannel
    :: client m a
    -> (Either SomeException a -> STM ())
    -> ClientWithResponseChannel client m

stmConnectionSource
  :: MonadUnliftIO m
  => TQueue (ClientWithResponseChannel client m)
  -> (forall a b. server m a -> client m b -> m (a, b))
  -> ConnectionSource server m
stmConnectionSource queue serveClient = ConnectionSource do
  ClientWithResponseChannel client sendResult <- readTQueue queue
  pure $ stmServerConnector client sendResult serveClient

stmServerConnector
  :: MonadUnliftIO m
  => client m x
  -> (Either SomeException x -> STM ())
  -> (forall a b. server m a -> client m b -> m (a, b))
  -> Connector server m
stmServerConnector client sendResult serveClient = Connector $ pure Connection
  { runConnection = \server -> do
      (a, b) <- serveClient server client `catch` \ex -> do
        atomically $ sendResult $ Left ex
        throwIO ex
      atomically $ sendResult $ Right b
      pure a
  }

stmClientConnector
  :: MonadUnliftIO m
  => TQueue (ClientWithResponseChannel client m)
  -> Connector client m
stmClientConnector queue = Connector $ pure Connection
  { runConnection = \client -> do
      readResult <- atomically do
        resultVar <- newEmptyTMVar
        writeTQueue queue $ ClientWithResponseChannel client $ putTMVar resultVar
        pure $ readTMVar resultVar
      either throwIO pure =<< atomically readResult
  }

data ClientServerPair server client m = ClientServerPair
  { clientServerSource :: ConnectionSource server m
  , clientServerConnector :: Connector client m
  }

clientServerPair
  :: forall server client m
   . MonadUnliftIO m
  => (forall a b. server m a -> client m b -> m (a, b))
  -> STM (ClientServerPair server client m)
clientServerPair serveClient = do
  queue <- newTQueue
  pure ClientServerPair
    { clientServerSource = stmConnectionSource queue serveClient
    , clientServerConnector = stmClientConnector queue
    }

data ChannelServerPair ps st server m = ChannelServerPair
  { channelServerSource :: ConnectionSource server m
  , channelServerChannel :: m (Channel ps 'AsClient st m)
  }

channelServerPair
  :: forall ps st server m
   . (MonadUnliftIO m, TestAgencyEquality ps)
  => ToPeer server ps 'AsServer st m
  -> STM (ChannelServerPair ps st server m)
channelServerPair toPeer = do
  queue <- newTQueue
  pure ChannelServerPair
    { channelServerSource = ConnectionSource do
        channel <- readTQueue queue
        pure $ Connector $ pure $ Connection $ runPeerOverChannel channel . toPeer
    , channelServerChannel = atomically do
        (clientChannel, serverChannel) <- channelPair
        writeTQueue queue serverChannel
        pure clientChannel
    }

channelPair
  :: forall ps st m
   . (MonadIO m, TestAgencyEquality ps)
  => STM (Channel ps 'AsClient st m, Channel ps 'AsServer st m)
channelPair = do
  c2s <- newTQueue
  s2c <- newTQueue
  pure (go c2s s2c, go s2c c2s)
  where
    go :: TQueue (AnyMessageAndAgency ps) -> TQueue (AnyMessageAndAgency ps) -> Channel ps pr st' m
    go sendQueue recvQueue = Channel
      { yield = \tok msg -> OutboundChannel
          { cast = atomically do
              writeTQueue sendQueue $ AnyMessageAndAgency tok msg
              pure $ go sendQueue recvQueue
          , call = \tokNext -> do
              atomically $ writeTQueue sendQueue $ AnyMessageAndAgency tok msg
              AnyMessageAndAgency tokNext' responseMessage <- atomically $ readTQueue recvQueue
              case testAgencyEquality tokNext tokNext' of
                Nothing -> error "Unexpected response agency"
                Just AgencyRefl -> pure ResponseChannel
                  { responseMessage
                  , responseChannel = go sendQueue recvQueue
                  }
          , close = \_ -> atomically $ writeTQueue sendQueue $ AnyMessageAndAgency tok msg
          }
      , await = \tok -> do
          AnyMessageAndAgency tok' message <- atomically $ readTQueue recvQueue
          case testAgencyEquality tok tok' of
            Nothing -> error "Unexpected peer agency"
            Just AgencyRefl -> pure InboundChannel
              { message
              , receive = pure $ go sendQueue recvQueue
              , respond = \tokNext Handler{..} -> withSendResponse \responseMessage -> do
                  atomically $ writeTQueue sendQueue $ AnyMessageAndAgency tokNext responseMessage
                  pure $ go sendQueue recvQueue
              , closed = \_ -> pure ()
              }
      }
