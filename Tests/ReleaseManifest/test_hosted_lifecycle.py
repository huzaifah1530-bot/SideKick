"""Integration contract for the UIKit-hosted shipping root, not the dormant @main App."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class HostedLifecycleTests(unittest.TestCase):
    def test_hosted_root_receives_uikit_lifecycle_and_samples_launch_state(self):
        root = (ROOT / 'SideKick/Views/Root/ContentView.swift').read_text()
        self.assertIn('UIApplication.didBecomeActiveNotification', root)
        self.assertIn('UIApplication.didEnterBackgroundNotification', root)
        self.assertIn('UIApplication.shared.applicationState', root)
        self.assertNotIn('@Environment(\\.scenePhase)', root)

    def test_resume_schedules_pending_check_and_background_invalidates_it(self):
        source = (ROOT / 'SideKick/App/AppEnvironment.swift').read_text()
        resume = source.split('func resumeGitHubChecks()', 1)[1].split('\n    }', 1)[0]
        self.assertIn('githubChecksSuspended = false', resume)
        self.assertIn('requestGitHubUpdateCheck()', resume)
        pause = source.split('func pauseGitHubChecks()', 1)[1].split('\n    }', 1)[0]
        for action in ('githubGeneration = UUID()', 'githubScanTask?.cancel()', 'githubCheckRequested = true'):
            self.assertIn(action, pause)
