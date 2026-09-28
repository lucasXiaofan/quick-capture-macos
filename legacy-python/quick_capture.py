#!/usr/bin/env python3
"""Local-only macOS menu-bar capture for Obsidian. See README.md."""
import base64
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import subprocess
import sys
import time
import uuid

import rumps
import Quartz
from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
from AppKit import (NSAlert, NSAlertFirstButtonReturn, NSApplication, NSBundle,
                    NSPopUpButton, NSTextField, NSView)
from Foundation import NSMakeRect
from pynput import keyboard

HERE = Path(__file__).resolve().parent
HOME = Path.home() / 'Library/Application Support/Obsidian Quick Capture'
CONFIG = HOME / 'config.json'
AGENT = Path.home() / 'Library/LaunchAgents/local.obsidian.quickcapture.plist'
HOTKEY_LABELS = {
    'image': 'Screenshot', 'text': 'Text',
    'diary_image': 'Diary screenshot', 'diary_text': 'Diary text',
}


def validate_hotkeys(keys):
    if set(keys) != set(HOTKEY_LABELS):
        raise ValueError('Keep all four shortcuts.')
    parsed = []
    for label, value in keys.items():
        try:
            combo = frozenset(keyboard.HotKey.parse(value.strip()))
        except Exception as error:
            raise ValueError(f'Invalid {HOTKEY_LABELS[label]} shortcut: {value}') from error
        if len(combo) < 2:
            raise ValueError(f'{HOTKEY_LABELS[label]} needs a modifier and key.')
        parsed.append(combo)
    if len(set(parsed)) != len(parsed):
        raise ValueError('Shortcuts must be different.')


def settings_dialog(config):
    """Native, small settings UI. Returns a copy only after Save."""
    alert = NSAlert.alloc().init()
    alert.setMessageText_('Quick Capture settings')
    alert.setInformativeText_('Enter shortcuts using <cmd>, <shift>, <alt>, <ctrl> plus a key.')
    alert.addButtonWithTitle_('Save')
    alert.addButtonWithTitle_('Cancel')
    panel = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 490, 238))
    fields = {}
    for row, (key, label) in enumerate(HOTKEY_LABELS.items()):
        y = 202 - row * 42
        name = NSTextField.labelWithString_(label)
        name.setFrame_(NSMakeRect(0, y + 3, 145, 24))
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(155, y, 330, 28))
        field.setStringValue_(config['hotkeys'][key])
        panel.addSubview_(name)
        panel.addSubview_(field)
        fields[key] = field
    label = NSTextField.labelWithString_('Main shortcuts save to')
    label.setFrame_(NSMakeRect(0, 7, 155, 24))
    target = NSPopUpButton.alloc().initWithFrame_pullsDown_(NSMakeRect(155, 4, 330, 30), False)
    target.addItemsWithTitles_(['Current note (diary fallback)', 'Diary only'])
    target.selectItemAtIndex_(1 if config.get('destination_mode') == 'diary' else 0)
    panel.addSubview_(label)
    panel.addSubview_(target)
    alert.setAccessoryView_(panel)
    if alert.runModal() != NSAlertFirstButtonReturn:
        return None
    updated = dict(config)
    updated['hotkeys'] = {key: field.stringValue().strip() for key, field in fields.items()}
    updated['destination_mode'] = 'diary' if target.indexOfSelectedItem() == 1 else 'current'
    validate_hotkeys(updated['hotkeys'])
    return updated


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


def permissions(prompt=False):
    """Request only the three capabilities actually needed; never elevate privileges."""
    access = bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: prompt}))
    screen = bool(Quartz.CGPreflightScreenCaptureAccess())
    listen = bool(Quartz.CGPreflightListenEventAccess())
    if prompt:
        if not screen:
            Quartz.CGRequestScreenCaptureAccess()
        if not listen:
            Quartz.CGRequestListenEventAccess()
    return access, screen, listen


def configure():
    if CONFIG.exists():
        return json.loads(CONFIG.read_text())
    rumps.alert('Choose your Obsidian vault', 'Select the vault folder, not a note. '
                'You can edit diary paths and shortcuts later from the menu.')
    result = run('/usr/bin/osascript', '-e',
                 'POSIX path of (choose folder with prompt "Choose your Obsidian vault")')
    if result.returncode:
        raise SystemExit(0)
    vault = Path(result.stdout.strip()).resolve()
    if not (vault / '.obsidian').is_dir():
        raise ValueError('This folder does not contain .obsidian. Choose a vault folder.')
    config = json.loads((HERE / 'config.json').read_text())
    config['vault'] = str(vault)
    daily = vault / '.obsidian/daily-notes.json'
    if daily.exists():
        daily = json.loads(daily.read_text())
        config['diary_folder'] = daily.get('folder', '')
        template = daily.get('template', '')
        config['template'] = template + ('.md' if template and not template.endswith('.md') else '')
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    return config


class Capture(rumps.App):
    def __init__(self):
        super().__init__('Obsidian Quick Capture', title='✎', quit_button='Quit')
        self.busy = False
        self.events = queue.Queue(maxsize=1)
        self.listener = None
        self.menu = ['Screenshot → current note', 'Text → current note',
                     'Screenshot → diary', 'Text → diary', None,
                     'Destination: Current note', 'Destination: Diary only',
                     'Shortcut settings…', 'Permissions…', 'Edit configuration…', 'Reload shortcuts',
                     'Check Obsidian connection', 'Open recovery folder',
                     'Start at login', 'Stop starting at login']
        for label in ['Screenshot → current note', 'Text → current note',
                      'Screenshot → diary', 'Text → diary']:
            self.menu[label].set_callback(self.menu_capture)
        for label in ['Start at login', 'Stop starting at login']:
            self.menu[label].set_callback(self.login)
        for label in ['Destination: Current note', 'Destination: Diary only']:
            self.menu[label].set_callback(self.set_destination)
        # First run asks for permissions before capturing or listening for keys.
        if not CONFIG.exists():
            rumps.alert('Quick Capture permissions', 'This app uses Accessibility and Input '
                        'Monitoring for global shortcuts, and Screen Recording for screenshots. '
                        'Nothing is uploaded. Approve the macOS prompts; a restart may be needed.')
            permissions(prompt=True)
        self.config = configure()
        self.reload(None)
        self.timer = rumps.Timer(self.tick, 0.15)
        self.timer.start()

    def bridge(self, action, **values):
        p = dict(action=action, vault=str(self.vault), **values)
        body = (HERE / 'bridge.js').read_text()
        code = ('(() => {const p=' + json.dumps(p) + '; const value=(() => {' + body +
                '})(); return "QC:"+btoa(unescape(encodeURIComponent(JSON.stringify(value))));})()')
        result = run(self.config['obsidian'], 'vault=' + self.vault.name,
                     'eval', 'code=' + code, timeout=12)
        match = re.search(r'QC:([A-Za-z0-9+/=]+)', result.stdout)
        if not match:
            raise RuntimeError('Obsidian CLI unavailable. Open your vault and enable Settings → '
                               'General → Advanced → Command line interface.\n' +
                               (result.stderr + result.stdout)[-600:])
        return json.loads(base64.b64decode(match[1]))

    @property
    def vault(self):
        return Path(self.config['vault']).expanduser().resolve()

    def enqueue(self, action):
        if not self.busy:
            try:
                self.events.put_nowait(action)
            except queue.Full:
                pass

    def menu_capture(self, sender):
        self.enqueue(('diary_' if 'diary' in sender.title else '') +
                     ('image' if sender.title.startswith('Screenshot') else 'text'))

    def update_destination_checks(self):
        diary = self.config.get('destination_mode', 'current') == 'diary'
        self.menu['Destination: Current note'].state = not diary
        self.menu['Destination: Diary only'].state = diary

    def set_destination(self, sender):
        config = dict(self.config)
        config['destination_mode'] = ('diary' if sender.title.endswith('Diary only')
                                      else 'current')
        CONFIG.write_text(json.dumps(config, indent=2) + '\n')
        self.config = config
        self.update_destination_checks()

    def tick(self, _):
        if self.busy or self.events.empty():
            return
        self.busy = True
        try:
            self.capture(self.events.get_nowait())
        except Exception as error:
            rumps.alert('Capture not confirmed', str(error))
        finally:
            self.busy = False

    def relative(self, value):
        path = (self.vault / value).resolve()
        return path.relative_to(self.vault).as_posix()  # Reject paths outside vault.

    def capture(self, action):
        now = dt.datetime.now()
        ident = uuid.uuid4().hex
        diary = self.relative(self.config['diary_folder'] + '/' + now.strftime('%Y-%m-%d.md')
                              if self.config['diary_folder'] else now.strftime('%Y-%m-%d.md'))
        destination = diary
        try:
            destination = self.bridge('snapshot', id=ident, diary=action.startswith('diary'),
                                      diary_path=diary)['path']
        except Exception:
            pass  # Capture first; preserve a recovery file if the CLI remains unavailable.
        picture = None
        if action.endswith('image'):
            if not permissions()[1]:
                self.show_permissions(None)
                return
            picture = self.vault / ('capture-' + now.strftime('%Y%m%d-%H%M%S-') + ident[:8] + '.png')
            run('/usr/sbin/screencapture', '-i', '-x', str(picture))
            if not picture.exists() or picture.stat().st_size == 0:
                if picture.exists():
                    picture.unlink()
                return  # Escape: no note or empty diary is created.
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        answer = rumps.Window(title='Quick Capture', message='Save to: ' + destination +
                              ('\nComment is optional.' if picture else ''),
                              ok='Save', cancel=True, dimensions=(440, 160)).run()
        if not answer.clicked:
            if picture:
                picture.unlink()  # Only our newly captured, not-yet-linked image.
            return
        if not picture and not answer.text.strip():
            return
        text = '\n' + (f'![[{picture.name}]]\n' if picture else '') + answer.text.strip() + '\n'
        recovery = HOME / 'recovery' / (ident + '.md')
        recovery.parent.mkdir(exist_ok=True)
        recovery.write_text(f'<!-- Intended destination: {destination} -->\n' + text)
        try:
            template_path = self.config.get('template', '')
            template = ((self.vault / self.relative(template_path)).read_text()
                        if template_path else '# ' + now.strftime('%Y-%m-%d') + '\n')
            template = template.replace('{{date:YYYY-MM-DD}}', now.strftime('%Y-%m-%d'))
            template = template.replace('{{date}}', now.strftime('%Y-%m-%d'))
            template = template.replace('{{time}}', now.strftime('%H:%M'))
            template = template.replace('{{title}}', now.strftime('%Y-%m-%d'))
            self.bridge('save', id=ident, diary_path=diary, template=template, text=text)
            for _ in range(20):
                status = self.bridge('status', id=ident)
                if status and not status.get('pending'):
                    if status.get('error'):
                        raise RuntimeError(status['error'])
                    recovery.unlink()
                    self.title = '✎ ✓'
                    return
                time.sleep(0.1)
            raise RuntimeError('Save acknowledgement timed out. Check the note before retrying.')
        except Exception as error:
            raise RuntimeError(f'{error}\n\nYour capture is preserved at:\n{recovery}') from error

    @rumps.clicked('Reload shortcuts')
    def reload(self, _):
        try:
            config = json.loads(CONFIG.read_text())
            keys = config['hotkeys']
            validate_hotkeys(keys)
            if config.get('destination_mode', 'current') not in ('current', 'diary'):
                raise ValueError('Destination must be current or diary.')
            self.config = config
            if self.listener:
                self.listener.stop()
            self.listener = keyboard.GlobalHotKeys(
                {key: lambda a=action: self.enqueue(
                    ('diary_' + a if self.config.get('destination_mode') == 'diary'
                     and not a.startswith('diary_') else a))
                 for action, key in keys.items()})
            self.listener.start()
            self.update_destination_checks()
        except Exception as error:
            rumps.alert('Configuration error', str(error))

    @rumps.clicked('Shortcut settings…')
    def shortcut_settings(self, _):
        try:
            updated = settings_dialog(self.config)
            if updated is None:
                return
            CONFIG.write_text(json.dumps(updated, indent=2) + '\n')
            self.reload(None)
        except Exception as error:
            rumps.alert('Settings not saved', str(error))

    @rumps.clicked('Permissions…')
    def show_permissions(self, _):
        access, screen, listen = permissions(prompt=True)
        rumps.alert('macOS permissions', f'Accessibility: {access}\nScreen Recording: {screen}\n'
                    f'Input Monitoring: {listen}\n\nEnable this app (or Python/Terminal when running '
                    'from source) in Privacy & Security. Quit and reopen after granting access.')
        run('/usr/bin/open', 'x-apple.systempreferences:com.apple.preference.security')

    @rumps.clicked('Edit configuration…')
    def edit(self, _):
        run('/usr/bin/open', '-t', str(CONFIG))

    @rumps.clicked('Open recovery folder')
    def recovery(self, _):
        (HOME / 'recovery').mkdir(exist_ok=True)
        run('/usr/bin/open', str(HOME / 'recovery'))

    @rumps.clicked('Check Obsidian connection')
    def check(self, _):
        try:
            self.bridge('status', id='check')
            rumps.alert('Connected', 'Obsidian CLI is responding for ' + self.vault.name)
        except Exception as error:
            rumps.alert('Not connected', str(error))

    def login(self, sender):
        if sender.title.startswith('Stop'):
            AGENT.unlink(missing_ok=True)
            return
        args = ([str(NSBundle.mainBundle().executablePath())] if getattr(sys, 'frozen', False)
                else [sys.executable, str(Path(__file__).resolve())])
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        AGENT.write_bytes(plistlib.dumps(dict(Label='local.obsidian.quickcapture',
                          ProgramArguments=args, RunAtLoad=True,
                          StandardErrorPath=str(HOME / 'error.log'))))
        # Register for next login, without launching a second copy now.
        rumps.alert('Login startup enabled', 'Quick Capture will start at your next login. '
                    'Keep the app or source folder in its current location.')


if __name__ == '__main__':
    HOME.mkdir(parents=True, exist_ok=True)
    lock = (HOME / 'app.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Quick Capture is already running.')
    Capture().run()
