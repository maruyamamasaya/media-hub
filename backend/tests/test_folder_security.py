import io
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import folder_security as privacy

ROOT='00000000-0000-4000-8000-000000000001'
PARENT='00000000-0000-4000-8000-000000000002'
CHILD='00000000-0000-4000-8000-000000000003'

class FolderSecurityTests(unittest.TestCase):
    def setUp(self):
        self.settings=privacy.empty_settings()
        self.settings['locks']=[privacy.make_lock(ROOT,PARENT,'012345'),privacy.make_lock(ROOT,CHILD,'654321')]
        self.value={'rootId':ROOT,'folders':[{'id':PARENT,'parentId':None,'name':'secret-parent'},{'id':CHILD,'parentId':PARENT,'name':'secret-child'}], 'items':[{'id':'item','folderId':CHILD}]}
    def test_parent_lock_no_metadata_and_wrong_password(self):
        self.assertIsNone(privacy.visible(self.value,self.settings,set()))
        with self.assertRaises(ValueError): privacy.unlock(self.settings,'wrong-password','owner')
    def test_separate_ancestor_locks_and_token_scope_expiry_revision(self):
        first=privacy.unlock(self.settings,'654321','owner',now=1000)['token']
        ids=privacy.grants(self.settings,first,'owner',now=1001)
        self.assertIsNone(privacy.visible(self.value,self.settings,ids))
        both=privacy.unlock(self.settings,'012345','owner',first,now=1001)['token']
        self.assertEqual(len(privacy.visible(self.value,self.settings,privacy.grants(self.settings,both,'owner',1002))['items']),1)
        self.assertFalse(privacy.grants(self.settings,both,'someone-else',1002))
        self.assertFalse(privacy.grants(self.settings,both,'owner',1400))
        self.assertFalse(privacy.grants(self.settings,both+'x','owner',1002))
        self.settings['revision']=ROOT
        self.assertFalse(privacy.grants(self.settings,both,'owner',1002))
    def test_protected_children_removed_from_counts(self):
        self.settings['locks']=self.settings['locks'][1:]
        value=privacy.visible(self.value,self.settings,set())
        self.assertEqual(len(value['folders']),1)
        self.assertFalse(value['items'])
        self.assertNotIn('secret-child',json.dumps(value))
    def test_invalid_config_fails_closed(self):
        self.settings['locks'][0]['verifier']='invalid'
        with self.assertRaises(ValueError): privacy.validate(self.settings)

    def test_pin_requires_six_ascii_digits_and_keeps_leading_zero(self):
        lock = privacy.make_lock(ROOT, PARENT, '000001')
        settings = privacy.empty_settings()
        settings['locks'] = [lock]
        self.assertIn('token', privacy.unlock(settings, '000001', 'owner'))
        for invalid in ['1234', '12345', '1234567', '１２３４５６', '12345a', 123456]:
            with self.assertRaises(ValueError):
                privacy.make_lock(ROOT, PARENT, invalid)

    def test_existing_password_verifier_still_unlocks(self):
        import hashlib
        lock = privacy.make_lock(ROOT, PARENT, '000001')
        lock['verifier'] = hashlib.pbkdf2_hmac('sha256', b'legacy-test-password', bytes.fromhex(lock['salt']), privacy.ITERATIONS).hex()
        settings = privacy.empty_settings()
        settings['locks'] = [lock]
        self.assertIn('token', privacy.unlock(settings, 'legacy-test-password', 'owner'))
