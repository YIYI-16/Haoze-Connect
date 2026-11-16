import unittest
from haoze_android_startup_acceptance import validate_ui


class AndroidStartupAcceptanceTest(unittest.TestCase):
    def test_initialization_error_cannot_pass_as_a_running_app(self):
        xml = '<hierarchy><node package="com.haoze.connect" text="Startup failed"/></hierarchy>'
        with self.assertRaises(ValueError):
            validate_ui(xml)

    def test_requires_the_login_screen_from_the_client_package(self):
        self.assertFalse(validate_ui('<hierarchy><node package="com.haoze.connect" text="Loading"/></hierarchy>'))
        self.assertFalse(validate_ui('<hierarchy><node package="other.app" text="Sign in with Haoze"/></hierarchy>'))
        self.assertTrue(validate_ui('<hierarchy><node package="com.haoze.connect" content-desc="Sign in with Haoze"/></hierarchy>'))


if __name__ == '__main__':
    unittest.main()
