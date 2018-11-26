{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE FlexibleContexts      #-}

module AgilePoker.Server (run) where

import Servant
import Data.Maybe (maybe)
import Data.ByteString (ByteString)
import Data.Maybe (maybe)
import Control.Monad (forM_, forever)
import Control.Concurrent (MVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Network.Wai (Response)
import Servant.API.WebSocket (WebSocket)
import Control.Exception (finally)
import qualified Network.Wai.Handler.Warp as Warp
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as TE
import qualified Network.WebSockets as WS
import qualified Control.Concurrent as Concurrent

import AgilePoker.Server.Authorization
import AgilePoker.Server.Static
import AgilePoker.Session
import AgilePoker.Event
import AgilePoker.UserInfo
import AgilePoker.Table


-- State


data ServerState = ServerState
  { sessions :: MVar Sessions
  , tables :: MVar Tables
  }


initialSessions :: IO ServerState
initialSessions = ServerState
  <$> Concurrent.newMVar emptySessions
  <*> Concurrent.newMVar emptyTables


-- API


type Api = "status"                                :> Get  '[JSON] T.Text
      :<|> "session" :> AuthProtect "header"       :> Get  '[JSON] Session
      :<|> "join"    :> ReqBody '[JSON] UserInfo   :> Post '[JSON] T.Text
      :<|> "stream"  :> AuthProtect "cookie"       :> WebSocket
      :<|> "tables"  :> Capture "tableid" TableId  :> "join"
                     :> ReqBody '[JSON] UserInfo   :> Post '[JSON] T.Text
      :<|> "tables"  :> AuthProtect "header"       :> ReqBody '[JSON] UserInfo   :> Post '[JSON] Table


api :: Proxy Api
api = Proxy


-- Server


genContext :: MVar Sessions -> Context (SessionAuth : SessionAuth ': '[])
genContext state =
  authCookieHandler state :. authHeaderHandler state :. EmptyContext


server :: ServerState -> Server Api
server state = status
           :<|> getSession
           :<|> join
           :<|> stream
           :<|> joinTable
           :<|> createTableHandler

  where
    status :: Handler T.Text
    status = pure "OK"

    getSession :: Session -> Handler Session
    getSession = pure

    join :: UserInfo -> Handler T.Text
    join UserInfo { userName=name } = do
      mSession <- liftIO $ Concurrent.modifyMVar (sessions state) $ addSession name

      case mSession of
        Just ( id', session ) -> do
            s <- liftIO $ Concurrent.readMVar (sessions state)

            -- broadcast join event
            liftIO $ broadcast s $ userJoined session

            pure $ TE.decodeUtf8 id'

        Nothing ->
            throwError $ err409 { errBody = "Name already taken" }

    stream :: MonadIO m => Session -> WS.Connection -> m ()
    stream session = liftIO . handleSocket (sessions state) session

    -- @TODO: implement
    joinTable :: TableId -> UserInfo -> Handler T.Text
    joinTable id' UserInfo { userName=name } =
      pure "x"

    createTableHandler :: Session -> UserInfo -> Handler Table
    createTableHandler session UserInfo { userName=name } =
      liftIO $ Concurrent.modifyMVar (tables state) $
        createTable session name


broadcast :: Sessions -> Event -> IO ()
broadcast state' event = do
    forM_ state' $ \(Session { sessionConnections=conns }) ->
      forM_ conns $ flip WS.sendTextData $ encodeEvent event


handleSocketEvent :: MVar Sessions -> WS.Connection -> IO ()
handleSocketEvent state' conn = forever $ do
  msg :: ByteString <- WS.receiveData conn
  -- state <- Concurrent.readMVar state'
  -- @TODO: implement
  pure ()


handleSocket :: MVar Sessions -> Session -> WS.Connection -> IO ()
handleSocket state' session conn = do
  let sessionId' = sessionId session

  -- assing connection
  mConnectionId <- Concurrent.modifyMVar state' $ pure . assignConnection sessionId' conn

  -- Sync state to new user
  state <- Concurrent.readMVar state'
  forM_ state $ WS.sendTextData conn . encodeEvent . userJoined

  case mConnectionId of
    Just ( connectionId, session ) ->
        -- Disconnect user at the end of session
        flip finally (disconnect ( sessionId', connectionId )) $ do
            -- ping thread
            WS.forkPingThread conn 30

            -- broadcast join event
            state <- Concurrent.readMVar state'
            broadcast state $ userStatusUpdate session

            -- assign handler
            handleSocketEvent state' conn

    Nothing ->
      -- @TODO: Add error handling
      -- but this is very unlikely situation
      pure ()

  where
    disconnect :: ( SessionId, Int ) -> IO ()
    disconnect id' = do
      -- disconnect
      Concurrent.modifyMVar_ state' $
        pure . disconnectSession id'

      -- broadcast
      state <- Concurrent.readMVar state'
      let session = getSession (fst id') state

      maybe (pure ()) (broadcast state . userStatusUpdate) session



app :: ServerState -> Application
app state = staticMiddleware $
    serveWithContext api (genContext $ sessions state) $
    server state


run :: Int -> IO ()
run port = do
  state <- initialSessions
  Warp.run port $ app state
