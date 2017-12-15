module Prometheus.Metric.Vector (
    Vector (..)
,   vector
,   withLabel
,   removeLabel
,   clearLabels
,   getVectorWith
) where

import Prometheus.Label
import Prometheus.Metric
import Prometheus.MonadMonitor

import Control.Applicative ((<$>))
import Data.Traversable (forM)
import qualified Data.Atomics as Atomics
import qualified Data.IORef as IORef
import qualified Data.Map.Strict as Map


type VectorState l m = (IO (Metric m), Map.Map l (Metric m))

data Vector l m = MkVector (IORef.IORef (VectorState l m))

-- | Creates a new vector of metrics given a label.
vector :: Label l => l -> IO (Metric m) -> IO (Metric (Vector l m))
vector labels gen = do
    ioref <- checkLabelKeys labels $ IORef.newIORef (gen, Map.empty)
    return Metric {
            handle  = MkVector ioref
        ,   collect = collectVector labels ioref
        }

checkLabelKeys :: Label l => l -> a -> a
checkLabelKeys keys r = foldl check r $ map fst $ labelPairs keys keys
    where
        check _ "instance" = error "The label 'instance' is reserved."
        check _ "job"      = error "The label 'job' is reserved."
        check _ "quantile" = error "The label 'quantile' is reserved."
        check a (k:ey)
            | validStart k && all validRest ey = a
            | otherwise = error $ "The label '" ++ (k:ey) ++ "' is not valid."
        check _ []         = error "Empty labels are not allowed."

        validStart c =  ('a' <= c && c <= 'z')
                     || ('A' <= c && c <= 'Z')
                     || c == '_'

        validRest c =  ('a' <= c && c <= 'z')
                    || ('A' <= c && c <= 'Z')
                    || ('0' <= c && c <= '9')
                    || c == '_'

-- TODO(will): This currently makes the assumption that all the types and info
-- for all sample groups returned by a metric's collect method will be the same.
-- It is not clear that this will always be a valid assumption.
collectVector :: Label l => l -> IORef.IORef (VectorState l m) -> IO [SampleGroup]
collectVector keys ioref = do
    (_, metricMap) <- IORef.readIORef ioref
    joinSamples <$> concat <$> mapM collectInner (Map.assocs metricMap)
    where
        collectInner (labels, metric) =
            map (adjustSamples labels) <$> collect metric

        adjustSamples labels (SampleGroup info ty samples) =
            SampleGroup info ty (map (prependLabels labels) samples)

        prependLabels l (Sample name labels value) =
            Sample name (labelPairs keys l ++ labels) value

        joinSamples []                      = []
        joinSamples s@(SampleGroup i t _:_) = [SampleGroup i t (extract s)]

        extract [] = []
        extract (SampleGroup _ _ s:xs) = s ++ extract xs

getVectorWith :: (Metric metric -> IO a)
              -> Metric (Vector label metric)
              -> IO [(label, a)]
getVectorWith f (Metric {handle = MkVector valueTVar}) = do
    (_, metricMap) <- IORef.readIORef valueTVar
    Map.assocs <$> forM metricMap f

-- | Given a label, applies an operation to the corresponding metric in the
-- vector.
withLabel :: (Label label, MonadMonitor m)
          => label
          -> (Metric metric -> IO ())
          -> Metric (Vector label metric)
          -> m ()
withLabel label f (Metric {handle = MkVector ioref}) = doIO $ do
    (gen, _) <- IORef.readIORef ioref
    newMetric <- gen
    metric <- Atomics.atomicModifyIORefCAS ioref $ \(_, metricMap) ->
        let maybeMetric = Map.lookup label metricMap
            updatedMap  = Map.insert label newMetric metricMap
        in  case maybeMetric of
                Nothing     -> ((gen, updatedMap), newMetric)
                Just metric -> ((gen, metricMap), metric)
    f metric

-- | Removes a label from a vector.
removeLabel :: (Label label, MonadMonitor m)
            => Metric (Vector label metric) -> label -> m ()
removeLabel (Metric {handle = MkVector valueTVar}) label =
    doIO $ Atomics.atomicModifyIORefCAS_ valueTVar f
    where f (desc, metricMap) = (desc, Map.delete label metricMap)

-- | Removes all labels from a vector.
clearLabels :: (Label label, MonadMonitor m)
            => Metric (Vector label metric) -> m ()
clearLabels (Metric {handle = MkVector valueTVar}) =
    doIO $ Atomics.atomicModifyIORefCAS_ valueTVar f
    where f (desc, _) = (desc, Map.empty)
