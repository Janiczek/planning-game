{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PlanningGame.Data.Table.Stream
  ( join
  , handler
  ) where

import           Control.Concurrent            (MVar)
import           Control.Monad                 (forM_, forever, mzero)
import           Data.Aeson.Types              (FromJSON (..), ToJSON (..),
                                                Value (..), object, (.:), (.=))
import           Data.ByteString               (ByteString)
import           Data.Text                     (Text)
import           Network.WebSockets            (Connection)

import qualified Control.Concurrent            as Concurrent
import qualified Control.Exception             as Exception
import qualified Data.Aeson                    as Aeson
import qualified Data.ByteString.Lazy          as LazyByteString
import qualified Data.Maybe                    as Maybe
import qualified Data.Text                     as Text
import qualified Network.WebSockets            as WS

import           PlanningGame.Api.GameSnapshot (snapshot)
import           PlanningGame.Data.Game        (Games, Vote)
import           PlanningGame.Data.Id          (Id)
import           PlanningGame.Data.Player      (Player, PlayerError (..),
                                                Players)
import           PlanningGame.Data.Session     (Session, SessionId)
import           PlanningGame.Data.Table       (Table (..), TableError (..),
                                                TableId, Tables)

import qualified PlanningGame.Data.Game        as Game
import qualified PlanningGame.Data.Player      as Player
import qualified PlanningGame.Data.Table       as Table


-- | Msg is incomming msg from client
data Msg
  = NewGame Text
  | FinishRound
  | NextRound Vote Text
  | Vote Vote
  | FinishGame Vote
  | RestartRound
  | KickPlayer Text


instance FromJSON Msg where
  parseJSON (Object v) =
    (v .: "msg") >>= \(msg :: String) ->
       case msg of
         "NewGame" ->
           NewGame <$> (v .: "name")

         "FinishRound" ->
           pure FinishRound

         "NextRound" ->
           NextRound
             <$> (v .: "vote")
             <*> (v .: "name")

         "Vote" ->
           Vote <$> (v .: "vote")

         "FinishGame" ->
           FinishGame <$> (v .: "vote")

         "RestartRound" ->
           pure RestartRound

         "KickPlayer" ->
           KickPlayer <$> (v .: "name")

         _ ->
           mzero

  parseJSON _ = mzero


-- | Event is outgoing event to clients
data Event
    = PlayerJoined Player
    | PlayerStatusUpdate Player
    | SyncTableState Table
    | GameStarted ( Id SessionId, Player ) Players Games
    | VoteAccepted Player
    | VotingEnded ( Id SessionId, Player ) Players Games
    | GameEnded ( Id SessionId, Player ) Players Games
    | PlayerKicked Player


instance ToJSON Event where
  toJSON (PlayerJoined player) =
    object
        [ "event"  .= Text.pack "PlayerJoined"
        , "player" .= player
        ]
  toJSON (PlayerStatusUpdate player) =
    object
        [ "event"  .= Text.pack "PlayerStatusUpdate"
        , "player" .= player
        ]
  toJSON (SyncTableState table) =
    object
        [ "event"        .= Text.pack "SyncTableState"
        , "table"        .= table
        , "nextGameName" .= maybe "Task-1" Game.autoNextName (Table.game table)
        ]
  toJSON (GameStarted dealer players games) =
    object
        [ "event" .= Text.pack "GameStarted"
        , "game"  .= snapshot dealer players games
        ]
  toJSON (VoteAccepted player) =
    object
        [ "event"  .= Text.pack "VoteAccepted"
        , "player" .= player
        ]
  toJSON (VotingEnded dealer players games) =
    object
        [ "event"        .= Text.pack "VotingEnded"
        , "game"         .= snapshot dealer players games
        , "nextGameName" .= Game.autoNextName games
        ]
  toJSON (GameEnded dealer players games) =
    object
        [ "event" .= Text.pack "GameEnded"
        , "game"  .= snapshot dealer players games
        ]
  toJSON (PlayerKicked player) =
    object
        [ "event"  .= Text.pack "PlayerKicked"
        , "player" .= player
        ]


encodeEvent :: Event -> ByteString
encodeEvent =
  LazyByteString.toStrict . Aeson.encode


-- Stream


broadcast :: Table -> Event -> IO ()
broadcast table event = do
  forM_ (Table.allConnections table) $ flip WS.sendTextData $ encodeEvent event


handleStreamMsg :: Session -> MVar Table -> Connection -> IO ()
handleStreamMsg session state conn = forever $ do
  bs :: LazyByteString.ByteString <- WS.receiveData conn
  let decoded :: Maybe Msg = Aeson.decode bs

  case decoded of
    -- @TODO: handle unrecosinable msg
    Nothing  -> pure ()
    Just msg ->
      Concurrent.modifyMVar_ state $ handleMsg conn session msg


disconnect :: MVar Table -> Id SessionId -> Int -> IO ()
disconnect state sessionId connId =
  Concurrent.modifyMVar_ state $ \table@Table { Table.banker=banker' } ->
    if fst banker' == sessionId then do
      let updatedTable = table { Table.banker = ( fst banker' , Player.removeConnectionFrom connId $ snd banker' ) }
      let player = snd $ banker updatedTable

      if Player.hasConnection player then
        pure ()

      else
        broadcast updatedTable $ PlayerStatusUpdate player

      pure updatedTable

    else do
      let updatedTable = table { Table.players = Player.disconnect sessionId connId (players table) }
      let mPlayer = Player.lookup sessionId $ Table.players updatedTable

      maybe mzero (broadcast updatedTable . PlayerStatusUpdate) mPlayer
      pure updatedTable


-- @TODO: Add check if session is not already present
join :: Session -> Id TableId -> Text -> Tables -> IO ( Either TableError Table )
join session tableId name' tables =
  let
    name =
      Text.strip name'
  in
  case Table.lookup tableId tables of
    Just mvar -> do
      table <- Concurrent.readMVar mvar

      if Player.name (snd $ banker table) == name then
        pure $ Left $ PlayerError NameTaken

      else
        let
            ePlayers = Player.add session name (players table)
        in
        case ePlayers of
          Right ( newPlayers, newPlayer ) ->
            Concurrent.modifyMVar mvar $ \t -> do
                let updatedTable = t { players = newPlayers }

                -- Broadcast to connections
                broadcast t $ PlayerJoined newPlayer

                pure ( updatedTable, Right updatedTable )

          Left err ->
             pure $ Left $ PlayerError err

    Nothing ->
      pure $ Left TableNotFound


handler :: MVar Tables -> Session -> Id TableId -> Connection -> IO ()
handler state session id' conn = do
  tables <- Concurrent.readMVar state
  let mTable = Table.lookup id' tables

  case mTable of
    Just tableState -> do

        -- 1. Assign connection to player
        mConnId <- Concurrent.modifyMVar tableState
          $ pure . Table.assignConnection session conn

        -- 2. Sync sate to new player
        table <- Concurrent.readMVar tableState
        WS.sendTextData conn $ encodeEvent $ SyncTableState table

        -- 3. Start player handler
        case mConnId of
            Just ( player, connId ) ->

                -- 3.1 Remove connection on disconnection
                flip Exception.finally (disconnect tableState session connId) $ do

                    -- 3.2 Ping Thread
                    WS.forkPingThread conn 30

                    -- 3.3 Broadcast join event
                    if Player.numberOfConnections player == 1 then do
                        table' <- Concurrent.readMVar tableState
                        broadcast table' $ PlayerStatusUpdate player

                    else
                        mzero

                    -- 3.4 Delegate to Msg handler
                    handleStreamMsg session tableState conn

            Nothing ->
                -- @TODO: player doesn't exist (session is not a member)
                mzero

    Nothing -> do
        -- @TODO: handle table doesn't exist
        putStrLn "Table not found"
        mzero

-- @TODO: refactor
handleMsg :: Connection -> Session -> Msg -> Table -> IO Table
handleMsg _ session (NewGame name) table
  | Table.isBanker session table
  , Maybe.isNothing (Table.game table) = do
      let game = Game.start name
      let players' = players table
      broadcast table $ GameStarted (banker table) players' game
      pure $ table { Table.game = Just game }

  | not $ Table.isBanker session table = do
      -- @TODO: Handle forbidden action
      pure $ table

  | otherwise =
      -- @TODO: Handle already started
      pure $ table

handleMsg _ session FinishRound table
  | Table.isBanker session table =
      case game table of
        Just games -> do
          let newGames = Game.finishCurrent games
          broadcast table $ VotingEnded (banker table) (players table) newGames
          pure $ table { Table.game = Just newGames }

        Nothing ->
          -- @TODO: handled non started game
          pure table

  | otherwise =
    -- @TODO: handle forbidden
    pure table

handleMsg _ session (NextRound vote name) table
  | Table.isBanker session table =
      case game table of
        Just games -> do
          case Game.nextRound vote name games of
            Left _ ->
              -- @TODO: missing err handling
              pure table
            Right newGames -> do
              broadcast table $ GameStarted (banker table) (players table) newGames
              pure $ table { Table.game = Just newGames }
        Nothing ->
          -- @TODO: handled non started game
          pure table

  | otherwise =
    -- @TODO: handle forbidden
    pure table

handleMsg _ session (Vote vote) table =
  case game table of
    Just game ->
      case Game.addVote session vote game of
        Right newGames -> do
          maybe (pure ()) (broadcast table . VoteAccepted)
            $ Player.get session
            $ Table.allPlayers table

          -- Auto end game when all voted
          if Game.allVoted (Table.allPlayers table) newGames then do
            let finishedNewGames = Game.finishCurrent newGames

            broadcast table $ VotingEnded (banker table) (players table) finishedNewGames
            pure $ table { Table.game = Just finishedNewGames }

          else
            pure $ table { Table.game = Just newGames }

        -- @TODO: can't vote error
        Left _ ->
          pure table

    Nothing ->
      -- @TODO: hanlde not started
      pure table

handleMsg _ session (FinishGame vote) table
  | Table.isBanker session table =
    case game table of
      Just games -> do
        case Game.complete vote games of
          Right newGames -> do
            broadcast table $ GameEnded (banker table) (players table) newGames
            pure $ table { Table.game = Just newGames }

          Left _ ->
            -- @TODO: handle already canceled
            pure table

      Nothing ->
        -- @TODO: handle game wasn't started
        pure table

  | otherwise =
      -- @TODO: handle forbidden
      pure table

handleMsg _ session RestartRound table
  | Table.isBanker session table =
    case game table of
      Just g -> do
        let game = Game.restartCurrent g
        let players' = Table.players table
        broadcast table $ GameStarted (banker table) players' game
        pure $ table { Table.game = Just game }

      Nothing ->
        -- @TODO: handle err
        pure table

  | otherwise =
      -- @TODO: handle forbidden
      pure table

handleMsg _ session (KickPlayer name) table
  | Table.isBanker session table
    || Table.sessionByName name table == Just session = do
    let maybePlayerData = Player.getByName name $ Table.players table

    case maybePlayerData of
      Just ( id', player ) -> do
        broadcast table $ PlayerKicked player
        pure $ table
            { Table.players = Player.kick id' $ Table.players table
            , Table.game = Game.removePlayerVotes id' <$> Table.game table
            }

      Nothing ->
        pure table

  | otherwise =
      -- @TODO: handle forbidden
      pure table
