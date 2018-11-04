-- | "Server" contains functions that serves the Penrose runtime over
--   websockets connection.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes, NoMonomorphismRestriction #-}

module Server where
import Utils (Autofloat, divLine, r2f, trRaw, fromRight)
import GHC.Generics
import Data.Monoid (mappend)
import Data.Text (Text)
import Control.Exception
import Control.Monad (forM_, forever, void)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar, forkIOWithUnmask)
import Data.Char (isPunctuation, isSpace)
import Data.Aeson
import Data.Maybe (fromMaybe)
import GHC.Float (float2Double)
import Network.WebSockets.Connection
import System.Time
import System.Random
import Debug.Trace
import qualified Shapes  as SD
import qualified Substance     as SU
import qualified Optimizer as O
import qualified Data.Map  as M
import qualified Data.Text                 as T
import qualified Data.Text.IO              as T
import qualified Network.WebSockets        as WS
import qualified Network.Socket            as S
import qualified Network.WebSockets.Stream as Stream
import qualified Control.Exception         as Exc (catch, ErrorCall)
import           System.Console.Pretty (Color (..), Style (..), bgColor, color, style, supportsPretty)

import GenOptProblem
import Env   (VarEnv)
import Style

type BackendState = GenOptProblem.State

-- COMBAK: remove TagExpr

-- Types used by the server, mainly for translation to JSON
-- TODO model this differently?
-- data ServerState = ServerState {
--     optState :: Maybe State,
--     env :: Maybe Env.VarEnv,
--     sty :: Maybe NS.StyProg
-- } deriving (Generic)

data ServerState
    = Editor VarEnv StyProg (Maybe BackendState)
    | Renderer BackendState

updateState :: ServerState -> BackendState -> ServerState
updateState (Renderer s) s' = Renderer s'
updateState (Editor e sty s) s' = Editor e sty $ Just s'

getBackendState :: ServerState -> BackendState
getBackendState (Renderer s) = s
getBackendState (Editor _ _ (Just s)) = s
getBackendState (Editor _ _ Nothing) = error "Server error: Backend state has not been initialized yet."

data Feedback
    = Cmd Command
    | Drag DragEvent
    | Update UpdateShapes
    | Edit SubstanceEdit
    deriving (Generic)

data Command = Command { command :: String }
     deriving (Show, Generic)

data DragEvent = DragEvent { name :: String,
                             xm :: Float,
                             ym :: Float }
     deriving (Show, Generic)

data SubstanceEdit = SubstanceEdit { program :: String }
     deriving (Show, Generic)

data UpdateShapes = UpdateShapes { shapes :: [SD.Shape Double] }
    deriving (Show, Generic)

data Frame = Frame { flag :: String,
                     shapes :: [SD.Shape Double]
                   } deriving (Show, Generic)

instance FromJSON Feedback
instance FromJSON Command
instance FromJSON DragEvent
instance FromJSON UpdateShapes
instance FromJSON SubstanceEdit
instance ToJSON Frame

wsSendJSON :: WS.Connection -> (SD.Shape Double) -> IO ()
wsSendJSON conn shape = WS.sendTextData conn $ encode shape

-- TODO use the more generic wsSendJSON?
wsSendJSONList :: WS.Connection -> ([SD.Shape Double]) -> IO ()
wsSendJSONList conn shapes = WS.sendTextData conn $ encode shapes

wsSendJSONFrame :: WS.Connection -> Frame -> IO ()
wsSendJSONFrame conn frame = WS.sendTextData conn $ encode frame

-- | 'servePenrose' is the top-level function that "Main" uses to start serving
--   the Penrose Runtime.
servePenrose :: String  -- the domain of the server
             -> Int  -- port number of the server
             -> BackendState  -- initial state of Penrose Runtime
             -> IO ()
servePenrose domain port initState = do
     putStrLn "Starting Server..."
     let s = Renderer initState
     Exc.catch (runServer domain port $ application s) handler
     where
        handler :: Exc.ErrorCall -> IO ()
        handler _ = putStrLn "Server Error"

-- | 'serveWithoutSub' TODO
serveWithoutSub :: String   -- ^ the domain of the server
                -> Int      -- ^ port number of the server
                -> VarEnv   -- ^ Element environment
                -> StyProg  -- ^ parsed Style program
                -> IO ()
serveWithoutSub domain port env styProg = do
     putStrLn "Starting Server..."
     let initState = Editor env styProg Nothing
     Exc.catch (runServer domain port $ application initState) handler
     where
        handler :: Exc.ErrorCall -> IO ()
        handler _ = putStrLn "Server Error"


application :: ServerState -> WS.ServerApp
-- Wait for first command, which __must be__ "SubstanceEdit"
-- TODO: make an explicit function for this for better readability?
application serverState@(Editor sty dsll Nothing) pending = do
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30 -- To keep the connection alive
    processCommand conn serverState


application (Renderer s) pending = do
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30 -- To keep the connection alive
    wsSendJSONList conn (shapesr s)
    loop conn $ Renderer $ O.step s

loop :: WS.Connection -> ServerState -> IO ()
loop conn serverState
    | optStatus (paramsr s) == EPConverged = do
        putStrLn "Optimization completed."
        putStrLn ("Current weight: " ++ show (weight (paramsr s)))
        wsSendJSONFrame conn Frame { flag = "final",
                                shapes = shapesr s :: [SD.Shape Double] }
        processCommand conn serverState
    | autostep s = stepAndSend conn serverState
    | otherwise = processCommand conn serverState
    where s = getBackendState serverState


processCommand :: WS.Connection -> ServerState -> IO ()
processCommand conn s = do
    putStrLn "Receiving Commands"
    msg_json <- WS.receiveData conn
    print msg_json
    divLine
    case decode msg_json of
        Just e -> case e of
            Cmd (Command cmd)             -> executeCommand cmd conn s
            Drag (DragEvent name xm ym)   -> dragUpdate name xm ym conn s
            Edit (SubstanceEdit subProg)  -> substanceEdit subProg conn s
            Update (UpdateShapes shapes)  -> updateShapes shapes conn s
        Nothing -> error "Error reading JSON"

toPolymorphics :: [SD.Shape Double] -> (forall a . (Autofloat a) => [SD.Shape a])
toPolymorphics = map toPolymorphic

toPolymorphic :: SD.Shape Double -> (forall a . (Autofloat a) => SD.Shape a)
toPolymorphic (ctor, properties) = (ctor, M.map toPolyProperty properties)

toPolyProperty :: SD.Value Double -> (forall a . (Autofloat a) => SD.Value a)
toPolyProperty v = case v of
    -- Not sure why these have to be rewritten from scratch...
    SD.FloatV n  -> SD.FloatV $ r2f n
    SD.BoolV x   -> SD.BoolV x
    SD.StrV x    -> SD.StrV x
    SD.IntV x    -> SD.IntV x
    SD.PtV (x,y) -> SD.PtV (r2f x, r2f y)
    -- TODO: rewrite this
    -- SD.PathV xs  -> SD.PathV $ map (\(x,y) -> (r2f x, r2f y)) xs
    SD.ColorV x  -> SD.ColorV x
    SD.FileV x   -> SD.FileV x
    SD.StyleV x  -> SD.StyleV x

substanceEdit :: String -> Connection -> ServerState -> IO ()
substanceEdit subIn conn (Renderer _) = error "Server Error: the Substance program cannot be updated when the server is in Renderer mode."
substanceEdit subIn conn serverState@(Editor env styProg s) = do
    putStrLn $ bgColor Green "Substance program received: " ++ subIn
    (subProg, (subEnv, eqEnv), labelMap) <- SU.parseSubstance "" subIn env
    let selEnvs = checkSels subEnv styProg
    let subss = find_substs_prog subEnv eqEnv subProg styProg selEnvs
    let trans = translateStyProg subEnv eqEnv subProg styProg labelMap :: forall a . (Autofloat a) => Either [Error] (Translation a)
    let newState = genOptProblemAndState (fromRight trans)
    let warns = warnings $ fromRight trans -- TODO: report warnings
    stepAndSend conn $ Editor env styProg $ Just newState

updateShapes :: [SD.Shape Double] -> Connection -> ServerState -> IO ()
updateShapes newShapes conn serverState =
    let polyShapes = toPolymorphics newShapes
        uninitVals = map toTagExpr $ shapes2vals polyShapes $ uninitializedPaths s
        trans' = insertPaths (uninitializedPaths s) uninitVals (transr s)
        newObjFn = genObjfn trans' (objFns s) (constrFns s) (varyingPaths s)
        news = s {
            shapesr = polyShapes,
            varyingState = shapes2floats polyShapes $ varyingPaths s,
            transr = trans',
            paramsr = (paramsr s) { weight = initWeight, optStatus = NewIter, overallObjFn = newObjFn }}
        nextServerS = updateState serverState news
    in if autostep s then stepAndSend conn nextServerS else loop conn nextServerS
    where s = getBackendState serverState

dragUpdate :: String -> Float -> Float -> WS.Connection -> ServerState -> IO ()
dragUpdate name xm ym conn serverState =
    let (xm', ym') = (r2f xm, r2f ym)
        newShapes  = map (\shape ->
            if SD.getName shape == name
                then SD.setX (SD.FloatV (xm' + SD.getX shape)) $ SD.setY (SD.FloatV (ym' + SD.getY shape)) shape
                else shape)
            (shapesr s)
        news = s { shapesr = newShapes,
                   varyingState = shapes2floats newShapes $ varyingPaths s,
                   paramsr = (paramsr s) { weight = initWeight, optStatus = NewIter }}
        nextServerS = updateState serverState news
    in if autostep s then stepAndSend conn nextServerS else loop conn nextServerS
    where s = getBackendState serverState

executeCommand :: String -> WS.Connection -> ServerState -> IO ()
executeCommand cmd conn s
    | cmd == "resample" = resampleAndSend conn s
    | cmd == "step"     = stepAndSend conn s
    | cmd == "autostep" =
        let os  = getBackendState s
            os' = os { autostep = not $ autostep os }
        in loop conn $ updateState s os'
    | otherwise         = putStrLn ("Can't recognize command " ++ cmd)

resampleAndSend, stepAndSend :: WS.Connection -> ServerState -> IO ()
resampleAndSend conn serverState = do
    let (newShapes, rng') = SD.sampleShapes (rng s) (shapesr s)
    let uninitVals = map toTagExpr $ shapes2vals newShapes $ uninitializedPaths s
    let trans' = insertPaths (uninitializedPaths s) uninitVals (transr s)
                    -- TODO: shapes', rng' = sampleConstrainedState (rng s) (shapesr s) (constrs s)
    let nexts = s { shapesr = newShapes, rng = rng',
                    transr = trans',
                    varyingState = shapes2floats newShapes $ varyingPaths s,
                    paramsr = (paramsr s) { weight = initWeight, optStatus = NewIter } }
    wsSendJSONList conn $ fst $ evalTranslation nexts
    let nextServerS = updateState serverState nexts
    loop conn nextServerS
    where s = getBackendState serverState

stepAndSend conn serverState = do
    let s = getBackendState serverState
    let nexts = O.step s
    wsSendJSONList conn (shapesr nexts :: [SD.Shape Double])
    -- loop conn (trRaw "state:" nexts)
    loop conn $ updateState serverState nexts


--------------------------------------------------------------------------------
-- Copied from WebSocket library

-- | This 'runServer' is exactly the same as the one in "Network.WebSocket". Duplicated for calling a customized version of 'runServerWith' with error messages enabled.
runServer :: String     -- ^ Address to bind
          -> Int        -- ^ Port to listen on
          -> WS.ServerApp  -- ^ Application
          -> IO ()      -- ^ Never returns
runServer host port app = runServerWith host port WS.defaultConnectionOptions app

-- | A version of 'runServer' which allows you to customize some options.
runServerWith :: String -> Int -> WS.ConnectionOptions -> WS.ServerApp -> IO ()
runServerWith host port opts app = S.withSocketsDo $
  bracket
  (WS.makeListenSocket host port)
  S.close
  (\sock ->
    mask_ $ forever $ do
      allowInterrupt
      (conn, _) <- S.accept sock
      void $ forkIOWithUnmask $ \unmask ->
        finally (unmask $ runApp conn opts app) (S.close conn)
    )

runApp :: S.Socket
       -> WS.ConnectionOptions
       -> WS.ServerApp
       -> IO ()
runApp socket opts app = do
       sock <- WS.makePendingConnection socket opts
       app sock
