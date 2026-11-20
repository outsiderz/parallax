// SPDX-License-Identifier: MIT
// Config-only revisions. Filesystem permissions and kernel flock via ucode fs.
// No sing-box process is started; check -c is used solely for validation.
import { lstat, mkdir, chmod, open, rename, unlink, rmdir, lsdir, glob, readfile } from 'fs';
import { sha256_file } from 'digest';

const STORE = '/etc/parallax/generated';
const ROOT = '/etc/parallax';
const ACTIVE = STORE + '/active.json';
const LIMIT = 10;

function fail(message) {
    // Never include file contents, credentials or executed program diagnostics.
    die('Parallax transaction rejected: ' + message + '\n');
}
function check(path, kind, mode) {
    let st = lstat(path);
    if (!st || st.type != kind || st.uid != 0 || st.mode != mode)
        fail('unsafe or missing private filesystem object');
    return st;
}
function directory(path) {
    if (!lstat(path) && !mkdir(path, 0o700))
        fail('cannot create private directory');
    check(path, 'directory', 0o700);
}
function regular(path) {
    check(path, 'file', 0o600);
}
function digest(path) {
    regular(path);
    let value = sha256_file(path);
    if (type(value) != 'string' ||
        match(value, /^[0-9a-f]{64}$/) == null)
        fail('cannot compute file digest');
    return value;
}

function activeHash() {
    if (!lstat(ACTIVE))
        return null;
    regular(ACTIVE);
    return digest(ACTIVE);
}
function candidate(path) {
    if (type(path) != 'string' ||
        match(path, /^\/run\/parallax\/candidate\.[A-Za-z0-9]{8}$/) == null)
        fail('candidate path is not allowed');

    check('/run/parallax', 'directory', 0o700);
    regular(path);
}
function validate(path) {
    // Every path comes from a fixed internal directory and validated filename;
    // shell metacharacters cannot reach this command. Suppress private data.
    if (system('sing-box check -c ' + path + ' >/dev/null 2>&1', 20000) != 0)
        fail('sing-box validation failed');
}
function stage(data, name) {
    // The underlying FS open() uses O_CREAT|O_EXCL, mode=0600.
    let file = STORE + '/.stage-' + name;
    let f = open(file, 'wx', 0o600);
    if (!f)
        fail('cannot reserve private staging file');
    if (f.write(data) != length(data) || !f.flush() || !f.close())
        fail('cannot write private staging file');
    regular(file);
    return file;
}
function syncDisk() {
    if (system('sync', 10000) != 0)
        fail('cannot synchronize filesystem');
}
function publish(data, name) {
    let file = stage(data, name);
    syncDisk();
    if (!rename(file, ACTIVE))
        fail('atomic active configuration promotion failed');
    syncDisk();
}
function getRevisions() {
    let files = glob(STORE + '/rev-*.json') ?? [];
    sort(files);
    return files;
}
function prune() {
    let files = getRevisions();
    let current = activeHash();
    let kept = 0;
    for (let i = length(files) - 1; i >= 0; i--) {
        let file = files[i];
        regular(file);
        if (kept < LIMIT || digest(file) == current) {
            kept++;
            continue;
        }
        if (!unlink(file))
            fail('revision retention failed');
    }
}
function apply(path) {
    candidate(path);
    validate(path);
    let newhash = digest(path);
    let oldhash = activeHash();
    if (newhash == oldhash) {
        printf('unchanged sha256=%s\n', newhash);
        return;
    }
    let t = gmtime(time());
    let stamp = sprintf('%04d%02d%02dT%02d%02d%02dZ',
        t.year, t.mon, t.mday, t.hour, t.min, t.sec);
    let pidMatch = match(readfile('/proc/self/stat', 64) ?? '', /^([0-9]+) /);
    if (!pidMatch)
        fail('cannot determine process identifier');
    let revision = sprintf('rev-%s-%s-%s', stamp, pidMatch[1], substr(newhash, 0, 12));
    let data = readfile(path);
    if (type(data) != 'string')
        fail('cannot read validated candidate');
    let saved = stage(data, 'revision-' + pidMatch[1]);
    if (!rename(saved, STORE + '/' + revision + '.json'))
        fail('cannot publish revision');

    publish(data, 'active-' + pidMatch[1]);
    prune();
    printf('applied revision=%s sha256=%s\n', revision, newhash);
}
function rollback(revision) {
    if (type(revision) != 'string' ||
        match(revision, /^rev-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{12}$/) == null)
        fail('invalid revision identifier');
    let path = STORE + '/' + revision + '.json';
    regular(path);
    validate(path);
    let newhash = digest(path);
    if (activeHash() == newhash) {
        printf('unchanged revision=%s sha256=%s\n', revision, newhash);
        return;
    }
    let data = readfile(path);
    if (type(data) != 'string')
        fail('cannot load revision');
    let m = match(readfile('/proc/self/stat', 64) ?? '', /^([0-9]+) /);
    if (!m)
        fail('cannot determine process identifier');
    publish(data, 'rollback-' + m[1]);
    printf('rolled_back revision=%s sha256=%s\n', revision, newhash);
}
function history() {
    let current = activeHash();
    if (current)
        printf('active sha256=%s\n', current);
    else
        print('active none\n');

    let files = getRevisions();
    for (let i = length(files) - 1; i >= 0; i--) {
        let file = files[i];
        regular(file);
        let sum = digest(file);
        let rev = match(file, /\/(rev-[^\/]+)\.json$/)[1];
        printf('%s %s sha256=%s\n', rev, sum == current ? 'active' : 'stored', sum);
    }
}
function diff(path) {
    candidate(path);
    validate(path);
    let current = activeHash();
    let value = digest(path);
    if (!current)
        printf('changed: no active configuration; candidate_sha256=%s\n', value);
    else if (current == value)
        printf('unchanged sha256=%s\n', value);
    else
        printf('changed: active_sha256=%s candidate_sha256=%s\n', current, value);
}
function deleteTree(path) {
    let st = lstat(path);
    if (!st)
        return;
    if (st.uid != 0 || st.type == 'link')
        fail('unsafe purge target');
    if (st.type == 'directory') {
        check(path, 'directory', 0o700);
        for (let filename in lsdir(path) ?? []) {
            if (filename == '.' || filename == '..' || index(filename, '/') >= 0)
                fail('invalid purge entry');
            deleteTree(path + '/' + filename);
        }
        if (!rmdir(path))
            fail('directory purge failed');
    }
    else if (st.type == 'file') {
        if (!unlink(path))
            fail('file purge failed');
    }
    else {
        fail('unsupported purge target');
    }
}
function purge() {
    // All data removal is opt-in; never executed by package postrm.
    // The caller must stop/disable the service before invoking this command.
    if (lstat(ROOT)) {
        check(ROOT, 'directory', 0o700);
        for (let filename in lsdir(ROOT) ?? []) {
            if (filename != 'generated' && filename != 'credentials' &&
                filename != '.reinstall-stopped')
                fail('unrecognized private data prevents automatic purge');
        }
        // A one-shot reinstall guard can remain after interrupted postinst.
        // Only delete a root-owned 0600 regular file. Fail closed before
        // touching credentials/revisions on links or insecure modes.
        let marker = ROOT + '/.reinstall-stopped';
        if (lstat(marker))
            regular(marker);
        // Current lock handle remains open while its directory is removed.
        // The exclusive file handle is released when the process exits.
        deleteTree(marker);
        deleteTree(ROOT + '/credentials');
        deleteTree(ROOT + '/generated');
        if (!rmdir(ROOT))
            fail('cannot remove private store root');
    }
    let conf = '/etc/config/parallax';
    if (lstat(conf)) {
        let st = lstat(conf);
        if (st.uid != 0 || st.type != 'file')
            fail('unsafe UCI conffile');
        if (!unlink(conf))
            fail('cannot delete UCI conffile');
    }
    print('purged: UCI configuration, credentials and generated revisions\n');
}
let command = ARGV[0];
let argument = ARGV[1] ?? null;
if (index([ 'apply', 'diff', 'history', 'rollback', 'purge' ], command) < 0)
    fail('unsupported transaction command');

if (command == 'purge') {
    if (argument != '--confirm-delete-all')
        fail('purge requires --confirm-delete-all');
    if (lstat(ROOT)) {
        check(ROOT, 'directory', 0o700);
        if (lstat(STORE)) {
            check(STORE, 'directory', 0o700);
            let lpath = STORE + '/.lock';
            let lk = open(lpath, 'a', 0o600);
            if (!lk || !chmod(lpath, 0o600) || !lk.lock('xn'))
                fail('cannot acquire purge transaction lock');
        }
    }
    purge();
}
else {
    directory(ROOT);
    directory(STORE);

    let lpath = STORE + '/.lock';
    if (lstat(lpath))
        regular(lpath);
    let lock = open(lpath, 'a', 0o600);
    if (!lock || !chmod(lpath, 0o600) || !lock.lock('xn'))
        fail('transaction lock busy or inaccessible');
    regular(lpath);

    if (command == 'apply') apply(argument);
    else if (command == 'rollback') rollback(argument);
    else if (command == 'diff') diff(argument);
    else if (command == 'history') history();
}
