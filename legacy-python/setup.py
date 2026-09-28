"""Optional standalone .app build: python setup.py py2app."""
from pathlib import Path
import os
from setuptools import setup

os.chdir(Path(__file__).resolve().parent)
setup(name='Obsidian Quick Capture', version='0.1.0',
      app=['quick_capture.py'],
      options={'py2app': {
          'resources': ['config.json', 'bridge.js'],
          'packages': ['rumps', 'pynput'],
          'includes': ['pynput.keyboard._darwin', 'pynput.mouse._darwin'],
          'plist': {
              'CFBundleIdentifier': 'local.obsidian.quickcapture',
              'CFBundleName': 'Obsidian Quick Capture',
              'LSUIElement': True,
              'NSHighResolutionCapable': True,
              'NSAppleEventsUsageDescription': 'Choose your Obsidian vault folder.'
          }}})
