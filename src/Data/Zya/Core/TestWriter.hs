{-# LANGUAGE DeriveDataTypeable, TemplateHaskell, DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module Data.Zya.Core.TestWriter(
  -- * The cloud service used to test readers and writers.
  testWriter
  ) where

import GHC.Generics (Generic)
import System.Environment(getArgs)

import Control.Concurrent.STM
import Control.Applicative((<$>))
import Control.Exception

import Control.Lens
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Trans
import Control.Monad.Reader

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Node as Node hiding (newLocalNode)

import Data.Binary
import Data.Data
import Data.Map
import Data.Monoid((<>))
import Data.Text(pack, unpack, Text)
import Data.Time(UTCTime, getCurrentTime)
import Data.Typeable
import Data.Zya.Core.Service
import Text.Printf
import Data.Zya.Core.ServiceTypes
writeMessage :: Server -> PMessage -> Process ()
writeMessage server aMessage =  do
  say $ printf "Sending message %s " (show aMessage)
  writer <- liftIO $ atomically $ findAvailableWriter server 
  case writer of 
    Just x -> liftIO $ atomically $ sendRemote (server) x aMessage
    Nothing -> say $ printf "No writer found. "
{-| Test writer to send a few messages -}
-- Find an available writer, if none found, error out.
-- If one found, send one or more test messages.
testWriter :: ServerReaderT () 
testWriter = do 
  serverConfiguration <- ask
  lift $ say $ printf "TestWriter %s" (show  serverConfiguration) 
  let aMessage = WriteMessage (Publisher $ pack "testPublisher") (1, pack "This is a test")
  lift $ writeMessage (serverConfiguration^.server) aMessage

eventLoop :: ServerReaderT ()
eventLoop = do
  serverConfiguration <- ask
  let server1 = serverConfiguration^.server 
  let serviceNameStr = unpack $ serverConfiguration^.serviceName
  let profile = serverConfiguration^.serviceProfile
  lift $ do 
    let sName = serviceNameStr
    selfPid <- getSelfPid
    spawnLocal (proxyProcess server1)
    say $ 
      printf "Updating topic allocator %s, profile : %s" (show TopicAllocator) 
        (show (profile)) 
    forever $
      receiveWait
        [ 
        match $ handleRemoteMessage server1
        , match $ handleMonitorNotification server1
        , matchIf (\(WhereIsReply l _) -> l == sName) $
                handleWhereIsReply server1 TestWriter
        , matchAny $ \_ -> return ()      -- discard unknown messages
        ]


handleRemoteMessage :: Server -> PMessage -> Process ()
handleRemoteMessage server aMessage@(CreateTopic aTopic) = do
  say $ printf ("Received message " <> (show aMessage))
  availableWriter <- liftIO $ atomically $ findAvailableWriter server 
  case availableWriter of
    Just a -> liftIO $ atomically $ sendRemote server a aMessage
    Nothing -> say $ printf $
                      ("No writer found. Dropping this message " <> (show aMessage))

handleRemoteMessage server aMessage@(ServiceAvailable serviceProfile processId) = do
  say $ printf("Received message " <> show aMessage)
  _ <- liftIO $ atomically $ addService server serviceProfile processId	
  return ()

handleRemoteMessage server unhandledMessage = 
  say $ printf ("Received unhandled message  " <> (show unhandledMessage))

handleMonitorNotification :: Server -> ProcessMonitorNotification -> Process ()
handleMonitorNotification server (ProcessMonitorNotification _ pid _) = do
  _ <- liftIO $ atomically $ removeProcess server pid 
  return ()
