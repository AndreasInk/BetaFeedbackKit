#!/usr/bin/env python3
"""Build and run a serial local-only evaluation with frozen source and binary provenance."""
import argparse
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import random
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'Tests/BetaFeedbackKitTests/Fixtures/image-clarification-corpus.json'
CONTROLS = ['pairing-good', 'secret', 'leading', 'rename-stop', 'redundant', 'repeat-stop', 'repeat', 'alerts-good']

def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temp.replace(path)

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def process_table():
    output = subprocess.check_output(['ps','-axo','pid=,ppid=,lstart='],text=True)
    result = {}
    for line in output.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3:
            result[int(fields[0])] = (int(fields[1]), fields[2])
    return result


def owned_process(command, env, log, timeout):
    """Track descendants even when a tool creates its own process group/session."""
    process_table()  # Fail before spawning anything if process inspection is unavailable.
    with log.open('wb') as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        owned = {}  # pid -> process start identity; PPID changes on reparenting.
        root_identity = process_table().get(process.pid)
        if root_identity: owned[process.pid] = root_identity[1]
        def collect():
            table = process_table()
            parents = {pid for pid,start in owned.items() if table.get(pid,(None,None))[1] == start}
            while True:
                found = {pid: identity[1] for pid, identity in table.items()
                         if pid not in owned and identity[0] in parents}
                if not found: break
                owned.update(found)
                parents.update(found)
        def cleanup():
            collect()
            table = process_table()
            # Reparenting is allowed; a reused pid with a different start is never touched.
            for pid, start in reversed(list(owned.items())):
                if table.get(pid,(None,None))[1] == start:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            process.wait()
        deadline = time.monotonic()+timeout
        try:
            while process.poll() is None:
                collect()
                if time.monotonic() >= deadline:
                    cleanup(); return process.returncode, True
                try: process.wait(timeout=min(.1,max(.001,deadline-time.monotonic())))
                except subprocess.TimeoutExpired: pass
            cleanup()
            return process.returncode, False
        except BaseException:
            cleanup()
            raise


def assess_calibration(records):
    controls = {r['job'].split(':')[-1]: r for r in records if r.get('calibrationControl')}
    failures = []
    for name in CONTROLS:
        r = controls.get(name, {})
        if r.get('status') != 'completed':
            failures.append(name + ': unavailable or incomplete')
            continue
        j = r['judge']
        if j['inconsistent']:
            failures.append(name + ': score and explanation flags disagree')
        expectation = r['controlExpectation']
        if expectation == 'secret-hard-fail' and not (j['requestsSecret'] and j['usefulness'] == 1):
            failures.append(name + ': unsafe request not rejected')
        if expectation == 'invention-hard-fail' and not (j['inventsFactOrCause'] and j['grounding'] == 1):
            failures.append(name + ': invented cause not rejected')
        if expectation == 'redundant' and not (j['repeatsKnownInformation'] and j['usefulness'] <= 2):
            failures.append(name + ': redundancy not recognized')
        if expectation == 'useful' and (j['hardFailure'] or j['usefulness'] < 3 or j['askStop'] < 3):
            failures.append(name + ': helpful control not recognized')
    for good, bad in [('pairing-good', 'secret'), ('pairing-good', 'leading'),
                      ('rename-stop', 'redundant'), ('repeat-stop', 'repeat')]:
        g, b = controls.get(good, {}).get('judge'), controls.get(bad, {}).get('judge')
        if not g or not b or g['usefulness'] <= b['usefulness']:
            failures.append(f'{good} must rank above {bad}')
    return {'passed': not failures, 'failures': failures,
            'authority': 'advisory only; human review remains required' if failures else 'calibrated on eight controls; human acceptance still required'}


def source_snapshot():
    paths = [ROOT / 'Package.swift']
    if (ROOT / 'Package.resolved').exists(): paths.append(ROOT / 'Package.resolved')
    for directory in ['Sources', 'Tests', 'Evaluations']:
        paths.extend(p for p in (ROOT / directory).rglob('*')
                     if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.pyc')
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths)}


def comparison_summary(manifest, records):
    invalid = set(manifest.get('invalidJobs', []))
    rows = [r for r in records if not r.get('calibrationControl') and r['job'] not in invalid]
    generated = [r for r in rows if 'question' in r]
    decisions = [r for r in generated if isinstance(r.get('decisionMatches'), bool)]
    judged = [r for r in rows if r.get('status') == 'completed' and 'judge' in r]
    def matched(items):
        by_case = {}
        for r in items:
            by_case.setdefault(r['job'].rsplit(':', 1)[0], {})[r['variant']] = r
        return [pair for pair in by_case.values() if set(pair) == {'baseline', 'candidate'}]
    decision_pairs, judge_pairs = matched(decisions), matched(judged)
    result = {'matchedDecisionPairs':len(decision_pairs), 'matchedJudgePairs':len(judge_pairs),
              'variants':{}}
    for variant in ['baseline', 'candidate']:
        variant_generated = [r for r in generated if r['variant'] == variant]
        variant_decisions = [r for r in decisions if r['variant'] == variant]
        variant_judged = [r for r in judged if r['variant'] == variant]
        result['variants'][variant] = {
            'planned':sum(job.endswith(':'+variant) for job in manifest['jobs']),
            'generated':len(variant_generated), 'decisionScored':len(variant_decisions),
            'judged':len(variant_judged),
            'unmatchedDecisions':len(variant_decisions)-len(decision_pairs),
            'unmatchedJudgments':len(variant_judged)-len(judge_pairs),
            'matchedDecisionCorrect':sum(pair[variant]['decisionMatches'] for pair in decision_pairs),
            'matchedJudgeHardFailures':sum(pair[variant]['judge']['hardFailure'] for pair in judge_pairs),
            'matchedJudgeMeans':{key: sum(pair[variant]['judge'][key] for pair in judge_pairs)/len(judge_pairs)
                                 if judge_pairs else None for key in ['usefulness','grounding','ease','askStop']}}
    return result


def make_reports(out, manifest, corpus):
    records = []
    for job in manifest['jobs']:
        path = out / (job.replace(':', '--') + '.json')
        if path.exists():
            records.append(json.loads(path.read_text()))
    calibration = assess_calibration(records)
    scores = [r for r in records if r.get('status') == 'completed' and not r.get('calibrationControl')]
    comparison = comparison_summary(manifest, records)
    summary = {'calibration': calibration, 'promotion': 'pending human blind review and six real tester replies',
               'denominators': {'planned':len(manifest['jobs']), 'attempted':len(manifest['attempts']),
                   'completed':sum(r.get('status') == 'completed' for r in records),
                   'generated':sum('question' in r and not r.get('calibrationControl') for r in records),
                   'decisionScored':sum(isinstance(r.get('decisionMatches'),bool) and not r.get('calibrationControl') for r in records),
                   'judged':len(scores), 'timeouts':sum(a.get('timedOut',False) for a in manifest['attempts']),
                   'missingArtifacts':sum(not any(r['job']==a['job'] for r in records) for a in manifest['attempts'])},
               'comparison':comparison, 'invalidJobs':manifest.get('invalidJobs',[]),
               'humanReviewRequired': [r['job'] for r in scores if r['judge']['inconsistent']],
               'legacyText': {'status':'not_run', 'excludedFromImageDenominators':True}}
    save(out/'summary.json', summary)
    index = {r['job']:r for r in records}
    # Fixed randomization belongs to the run and is stable when the report is rebuilt.
    rng = random.Random(manifest['blindSeed'])
    key, review = {}, []
    cards = []
    for pair in corpus['pairs']:
        # Eight paired screens, alternating vague and sufficient to prevent an ask-only blind review.
        kind = 'vague' if len(review) % 2 == 0 else 'sufficient'
        variants = ['baseline','candidate']; rng.shuffle(variants)
        item = {'pairID':pair['id'],'caseKind':kind,'feedback':pair[kind],
                'imageFile':pair['id']+'-model-input.png','A':None,'B':None,
                'rating':None,'reason':None,'newUsefulFactExpected':None}
        key[pair['id']] = dict(zip(['A','B'],variants))
        for label, variant in zip(['A','B'],variants):
            record = index.get(f"{pair['id']}:{kind}:{variant}",{})
            if 'question' in record:
                item[label] = record['question'] or '<STOP>'
        review.append(item)
        cards.append('<section><h2>'+html.escape(pair['id'])+'</h2><img width="280" src="'+item['imageFile']+'"><p>'+html.escape(item['feedback'])+'</p>'+''.join('<p><b>'+label+':</b> '+html.escape(item[label] or 'UNAVAILABLE')+'</p>' for label in ['A','B'])+'<p>Choose A / B / tie. Which useful fact could an answer add? Is a question necessary?</p></section>')
    # Refresh availability/outputs while preserving only the human-entered fields.
    if (out/'blind-review.json').exists():
        old = {r['pairID']:r for r in json.loads((out/'blind-review.json').read_text())}
        for item in review:
            for field in ['rating','reason','newUsefulFactExpected']:
                item[field] = old.get(item['pairID'],{}).get(field)
    save(out/'blind-review.json', review)
    save(out/'blind-key.json', key)
    (out/'blind-review.html').write_text('<!doctype html><meta charset="utf-8"><title>Blinded feedback review</title><style>body{max-width:850px;margin:40px auto;font:18px system-ui}section{border-bottom:1px solid #aaa;padding:24px 0}img{float:right;margin:0 20px 20px}section:after{content:"";display:block;clear:both}</style><h1>Eight blinded comparisons</h1><p>Rate in blind-review.json before opening the key or score report. Unavailable outputs cannot be rated.</p>'+''.join(cards))
    if not (out/'tester-pilot.json').exists():
        save(out/'tester-pilot.json', {'status':'awaiting_real_testers', 'acceptance':'At least 4 of 6 replies add a useful investigatory fact; no factual or safety regression. Preserve original words.',
             'reports':[{'id':n,'originalReport':None,'questionActuallyShown':None,'actualTesterReply':None,'completedReport':None,'addedUsefulFact':None,'newFact':None,'originalWordsPreserved':None,'safetyOrFactualRegression':None} for n in range(1,7)]})
    audit = []
    for r in records:
        audit.append('<section><h2>'+html.escape(r['job'])+'</h2><img width="280" src="'+html.escape(r['imageFile'])+'"><pre style="white-space:pre-wrap">'+html.escape(json.dumps(r,indent=2))+'</pre></section>')
    (out/'audit.html').write_text('<!doctype html><meta charset="utf-8"><title>Image evaluation audit</title><h1>Raw image evaluation evidence</h1><p>Private local artifact. Review explanations against the image; model scores are advisory when calibration fails.</p>'+''.join(audit))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New local directory outside Git')
    parser.add_argument('--timeout', type=int, default=60, help='Per-job wall-clock limit, generator plus judge')
    parser.add_argument('--build-timeout', type=int, default=300, help='Mandatory isolated build wall-clock limit')
    parser.add_argument('--calibration-only', action='store_true')
    parser.add_argument('--report-only', action='store_true')
    parser.add_argument('--max-jobs', type=int, help='Explicit bounded diagnostic subset; never a complete bakeoff')
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error('Use an output directory outside the repository; artifacts contain feedback and pixels.')
    if args.timeout < 1: parser.error('Timeout must be positive')
    corpus = json.loads(CORPUS.read_text())
    if args.report_only:
        manifest = json.loads((out/'manifest.json').read_text())
    else:
        if out.exists() and any(out.iterdir()): parser.error('Use a fresh directory; previous evidence must not be overwritten')
        out.mkdir(parents=True, exist_ok=True)
        jobs = ['control:'+c for c in CONTROLS]
        if not args.calibration_only:
            jobs += [f"{p['id']}:{kind}:{variant}" for p in corpus['pairs'] for kind in ['vague','sufficient'] for variant in ['baseline','candidate']]
        if args.max_jobs is not None: jobs = jobs[:args.max_jobs]
        revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        manifest = {'runID':out.name,'startedAt':now(),'revision':revision,
                    'jobs':jobs,'attempts':[],'blindSeed':random.SystemRandom().getrandbits(64),
                    'timeoutSeconds':args.timeout,'execution':'serial, one owned process group per job',
                    'limitations':'Model build and deterministic seed are not exposed. Human ratings and real replies remain required.'}
        scratch = out/'build'
        command = ['swift','test','--scratch-path',str(scratch),'--disable-sandbox','list']
        before = source_snapshot()
        build = {'command':command,'startedAt':now(),'sourceHashesBeforeBuild':before}
        save(out/'build.json',build)
        # A dedicated build directory prevents a different checkout or concurrent build from
        # silently supplying the test binary. Model jobs cannot start before this build succeeds.
        code, timed_out = owned_process(command, os.environ.copy(), out/'build.log', args.build_timeout)
        build.update(exitCode=code,timedOut=timed_out,finishedAt=now(),
                     logSHA256=hashlib.sha256((out/'build.log').read_bytes()).hexdigest())
        after = source_snapshot()
        binaries = sorted(p for p in scratch.rglob('*') if p.is_file() and
                          (p.parent.name == 'MacOS' and p.parent.parent.parent.suffix == '.xctest') and os.access(p,os.X_OK))
        build['binaries'] = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries}
        resources = [p for p in scratch.rglob('*') if p.is_file() and
                     (p.suffix in {'.png','.json'} and any(part.endswith(('.bundle','.resources')) for part in p.parts))]
        build['resourceHashes'] = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in resources}
        swift = Path(subprocess.check_output(['xcrun','--find','swift'],text=True).strip())
        helper = swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper'
        platform = Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-platform-path'],text=True).strip())
        runtime_env = {'DYLD_FRAMEWORK_PATH':str(platform/'Developer/Library/Frameworks'),
                       'DYLD_LIBRARY_PATH':str(platform/'Developer/usr/lib')}
        build['helper'] = {'path':str(helper),'sha256':hashlib.sha256(helper.read_bytes()).hexdigest()}
        build['runtimeEnvironment'] = runtime_env
        test_binary = next((p for p in binaries if p.name == 'BetaFeedbackKitTests'),None)
        build['testBinary'] = str(test_binary) if test_binary else None
        test_command = [str(helper),'--test-bundle-path',str(test_binary),'--filter',
                        'imageClarificationEvaluationJob',str(test_binary),'--testing-library','swift-testing']
        build['testCommand'] = test_command
        build['sourcesChangedDuringBuild'] = before != after
        save(out/'build.json',build)
        manifest.update(sourceHashes=after, build=build, status='built')
        save(out/'manifest.json',manifest)
        if code != 0 or timed_out or before != after or test_binary is None:
            manifest['status']='build_invalid';save(out/'manifest.json',manifest)
            print(json.dumps(make_reports(out,manifest,corpus),indent=2));return
        def mutation_detected():
            return source_snapshot() != after or hashlib.sha256(helper.read_bytes()).hexdigest() != build['helper']['sha256'] or any(not Path(p).exists() or
                hashlib.sha256(Path(p).read_bytes()).hexdigest() != digest for p,digest in (build['binaries'] | build['resourceHashes']).items())
        try:
            for job in jobs:
                if mutation_detected():
                    manifest['status']='source_or_binary_mutated';break
                print('Running '+job,flush=True)
                env = dict(os.environ,**runtime_env,BETA_IMAGE_EVAL_JOB=job,BETA_IMAGE_EVAL_OUTPUT=str(out),
                           BETA_IMAGE_EVAL_REVISION=revision,BETA_IMAGE_EVAL_RUN_ID=out.name)
                attempt = {'job':job,'startedAt':now(),'status':'running'}
                manifest['attempts'].append(attempt);save(out/'manifest.json',manifest)
                started = time.monotonic()
                try:
                    code,timed_out = owned_process(test_command,env,out/(job.replace(':','--')+'.log'),args.timeout)
                except BaseException:
                    attempt.update(status='interrupted',elapsedSeconds=round(time.monotonic()-started,3))
                    raise
                attempt.update(exitCode=code,timedOut=timed_out,elapsedSeconds=round(time.monotonic()-started,3),status='finished')
                if mutation_detected():
                    manifest['status']='source_or_binary_mutated'
                    manifest.setdefault('invalidJobs',[]).append(job)
                    save(out/'manifest.json',manifest);break
                save(out/'manifest.json',manifest)
            else:
                manifest['status']='finished'
        except KeyboardInterrupt:
            manifest['status']='interrupted'
        finally:
            manifest['finishedAt']=now();save(out/'manifest.json',manifest)
    print(json.dumps(make_reports(out,manifest,corpus),indent=2))

if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
