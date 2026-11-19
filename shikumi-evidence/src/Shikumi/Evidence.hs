-- | Production-evidence optimization and promotion reports.
--
-- A trusted job hands 'runEvidenceJob' a sealed dataset of production evidence
-- ("Shikumi.Evidence.Dataset"), a baseline program artifact
-- ("Shikumi.Evidence.Artifact"), an optimizer with a budget, and a declared metric
-- policy ("Shikumi.Evidence.Policy"). It receives a candidate program artifact and
-- a comparison report ("Shikumi.Evidence.Report") whose conclusion is exactly one
-- of 'Improved', 'Regressed', 'Inconclusive' or 'Invalid', together with the
-- recordings ("Shikumi.Evidence.Recording") that let anyone replay the job and
-- reproduce both digests. A lifecycle owner verifies a report with
-- 'verifyReportBinding' before asking anyone to approve anything. This package
-- decides the comparison only: it never activates a candidate.
module Shikumi.Evidence
  ( module Shikumi.Evidence.Digest,
    module Shikumi.Evidence.Source,
    module Shikumi.Evidence.Dataset,
    module Shikumi.Evidence.Artifact,
    module Shikumi.Evidence.Policy,
    module Shikumi.Evidence.Report,
    module Shikumi.Evidence.Recording,
    module Shikumi.Evidence.Exposure,
    module Shikumi.Evidence.Driver,
  )
where

import Shikumi.Evidence.Artifact
import Shikumi.Evidence.Dataset
import Shikumi.Evidence.Digest
import Shikumi.Evidence.Driver
import Shikumi.Evidence.Exposure
import Shikumi.Evidence.Policy
import Shikumi.Evidence.Recording
import Shikumi.Evidence.Report
import Shikumi.Evidence.Source
