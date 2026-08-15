#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

const READY_STATES = new Set(['READY_FOR_OPERATOR', 'ACCEPTANCE_COMPLETE']);
const REVIEW_STATES = new Set([
  'IMPLEMENTING',
  'READY_FOR_INTEGRATION_REVIEW',
  'INTEGRATION_REVIEW_IN_PROGRESS',
  'BLOCKED_FINDINGS',
  'INCONCLUSIVE_REVIEW',
  ...READY_STATES
]);
const ROW_STATES = new Set(['SATISFIED', 'UNSATISFIED', 'UNCERTAIN']);
const CLOSED_QUEUE_STATES = new Set(['CLOSED', 'NOT_APPLICABLE']);
const RESOLVED_FINDING_STATES = new Set(['RESOLVED', 'DISMISSED']);
const PASSING_CHECK_STATES = new Set(['PASSED', 'NOT_APPLICABLE']);
const ALLOWED_METADATA_PREFIXES = ['plans/agent-reviews/', 'plans/agent-handoffs/'];

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function git(repoRoot, args, { encoding = 'utf8' } = {}) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding,
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.status !== 0) {
    fail(`git ${args.join(' ')} failed: ${String(result.stderr).trim()}`);
  }
  return result.stdout;
}

function normalizeRepoPath(repoRoot, candidate) {
  const absolute = path.resolve(repoRoot, candidate);
  const relative = path.relative(repoRoot, absolute).replaceAll('\\', '/');
  if (!relative || relative.startsWith('../') || path.isAbsolute(relative)) {
    fail(`path must resolve inside the repository: ${candidate}`);
  }
  return relative;
}

function normalizeMetadataPaths(repoRoot, candidates) {
  return [...new Set(candidates.map((candidate) => normalizeRepoPath(repoRoot, candidate)))].sort(
    (left, right) => left.localeCompare(right)
  );
}

function assertAllowedMetadataPaths(paths) {
  for (const metadataPath of paths) {
    if (!ALLOWED_METADATA_PREFIXES.some((prefix) => metadataPath.startsWith(prefix))) {
      fail(
        `excluded metadata path must be under ${ALLOWED_METADATA_PREFIXES.join(' or ')}: ${metadataPath}`
      );
    }
  }
}

function digestArtifacts(repoRoot, artifactPaths) {
  if (!Array.isArray(artifactPaths) || artifactPaths.length === 0) {
    fail('at least one source/policy artifact is required');
  }
  const records = artifactPaths
    .map((candidate) => normalizeRepoPath(repoRoot, candidate))
    .sort((left, right) => left.localeCompare(right))
    .map(
      (relativePath) =>
        `${relativePath}\0${sha256(readFileSync(path.join(repoRoot, relativePath)))}`
    );
  return sha256(records.join('\n'));
}

function buildTreeIdentity({
  repoRoot,
  baseCommit,
  sourceArtifacts,
  policyArtifacts,
  excludedMetadataPaths
}) {
  const resolvedBase = git(repoRoot, ['rev-parse', '--verify', `${baseCommit}^{commit}`]).trim();
  const headCommit = git(repoRoot, ['rev-parse', '--verify', 'HEAD^{commit}']).trim();
  const excluded = normalizeMetadataPaths(repoRoot, excludedMetadataPaths);
  assertAllowedMetadataPaths(excluded);
  const pathspec = ['.', ...excluded.map((entry) => `:(exclude)${entry}`)];
  const aggregateDiff = git(repoRoot, ['diff', '--binary', resolvedBase, '--', ...pathspec], {
    encoding: null
  });
  const stagedDiff = git(repoRoot, ['diff', '--cached', '--binary', '--', ...pathspec], {
    encoding: null
  });
  const untrackedOutput = git(repoRoot, ['ls-files', '--others', '--exclude-standard', '-z'], {
    encoding: null
  });
  const untracked = untrackedOutput
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .map((entry) => normalizeRepoPath(repoRoot, entry))
    .filter((entry) => !excluded.includes(entry))
    .sort((left, right) => left.localeCompare(right))
    .map(
      (relativePath) =>
        `${relativePath}\0${sha256(readFileSync(path.join(repoRoot, relativePath)))}`
    );

  return {
    baseCommit: resolvedBase,
    headCommit,
    aggregateDiffSha256: sha256(aggregateDiff),
    stagedDiffSha256: sha256(stagedDiff),
    untrackedFilesSha256: sha256(untracked.join('\n')),
    sourceArtifactsSha256: digestArtifacts(repoRoot, sourceArtifacts),
    policyArtifactsSha256: digestArtifacts(repoRoot, policyArtifacts),
    excludedMetadataPaths: excluded
  };
}

function parseArguments(argv) {
  const [command, ...rest] = argv;
  const values = new Map();
  let allowBlocked = false;
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (token === '--allow-blocked') {
      allowBlocked = true;
      continue;
    }
    if (!token.startsWith('--') || !rest[index + 1] || rest[index + 1].startsWith('--')) {
      fail(`invalid argument near ${token}`);
    }
    const key = token.slice(2);
    values.set(key, [...(values.get(key) ?? []), rest[index + 1]]);
    index += 1;
  }
  return { command, values, allowBlocked };
}

function one(values, key) {
  const matches = values.get(key) ?? [];
  if (matches.length !== 1) fail(`expected exactly one --${key}`);
  return matches[0];
}

function many(values, key) {
  return values.get(key) ?? [];
}

function requireNonEmptyString(value, label, errors) {
  if (typeof value !== 'string' || value.trim() === '') errors.push(`${label} must be non-empty`);
}

function validateArtifactShape(artifact) {
  const errors = [];
  if (artifact?.schemaVersion !== 1) errors.push('schemaVersion must be 1');
  requireNonEmptyString(artifact?.taskId, 'taskId', errors);
  if (artifact?.state === 'COMPLETE')
    errors.push(
      'legacy COMPLETE is forbidden; use READY_FOR_OPERATOR or operator-owned ACCEPTANCE_COMPLETE'
    );
  if (!REVIEW_STATES.has(artifact?.state)) errors.push(`state is invalid: ${artifact?.state}`);
  if (!Array.isArray(artifact?.sourceArtifacts) || artifact.sourceArtifacts.length === 0)
    errors.push('sourceArtifacts must be non-empty');
  if (!Array.isArray(artifact?.policyArtifacts) || artifact.policyArtifacts.length === 0)
    errors.push('policyArtifacts must be non-empty');

  for (const key of [
    'baseCommit',
    'headCommit',
    'aggregateDiffSha256',
    'stagedDiffSha256',
    'untrackedFilesSha256',
    'sourceArtifactsSha256',
    'policyArtifactsSha256'
  ]) {
    requireNonEmptyString(artifact?.treeIdentity?.[key], `treeIdentity.${key}`, errors);
  }
  if (!Array.isArray(artifact?.treeIdentity?.excludedMetadataPaths))
    errors.push('treeIdentity.excludedMetadataPaths must be an array');

  requireNonEmptyString(artifact?.reviewer?.name, 'reviewer.name', errors);
  requireNonEmptyString(artifact?.reviewer?.model, 'reviewer.model', errors);
  requireNonEmptyString(artifact?.reviewer?.role, 'reviewer.role', errors);
  requireNonEmptyString(artifact?.reviewer?.reviewedAt, 'reviewer.reviewedAt', errors);
  if (typeof artifact?.reviewer?.independentFromPrimaryImplementation !== 'boolean')
    errors.push('reviewer.independentFromPrimaryImplementation must be boolean');

  for (const axis of ['standards', 'spec', 'integrationRuntime']) {
    if (!ROW_STATES.has(artifact?.reviewAxes?.[axis]?.status))
      errors.push(`reviewAxes.${axis}.status must be SATISFIED, UNSATISFIED, or UNCERTAIN`);
    if (!Array.isArray(artifact?.reviewAxes?.[axis]?.findingIds))
      errors.push(`reviewAxes.${axis}.findingIds must be an array`);
  }

  if (!Array.isArray(artifact?.expectedCriteria) || artifact.expectedCriteria.length === 0) {
    errors.push('expectedCriteria must copy every source acceptance criterion');
  } else {
    artifact.expectedCriteria.forEach((criterion, index) =>
      requireNonEmptyString(criterion, `expectedCriteria[${index}]`, errors)
    );
    if (new Set(artifact.expectedCriteria).size !== artifact.expectedCriteria.length)
      errors.push('expectedCriteria must not contain duplicates');
  }

  if (!Array.isArray(artifact?.acceptanceMatrix) || artifact.acceptanceMatrix.length === 0) {
    errors.push('acceptanceMatrix must contain one row per criterion');
  } else {
    artifact.acceptanceMatrix.forEach((row, index) => {
      for (const key of ['criterion', 'fileOrSymbol', 'verification', 'risk'])
        requireNonEmptyString(row?.[key], `acceptanceMatrix[${index}].${key}`, errors);
      if (!ROW_STATES.has(row?.status)) errors.push(`acceptanceMatrix[${index}].status is invalid`);
    });
    const matrixCriteria = artifact.acceptanceMatrix.map((row) => row?.criterion);
    if (new Set(matrixCriteria).size !== matrixCriteria.length)
      errors.push('acceptanceMatrix must not contain duplicate criteria');
    for (const criterion of artifact?.expectedCriteria ?? []) {
      if (!matrixCriteria.includes(criterion))
        errors.push(`acceptanceMatrix is missing expected criterion: ${criterion}`);
    }
    for (const criterion of matrixCriteria) {
      if (!(artifact?.expectedCriteria ?? []).includes(criterion))
        errors.push(`acceptanceMatrix contains undeclared criterion: ${criterion}`);
    }
  }

  if (!Array.isArray(artifact?.requiredChecks) || artifact.requiredChecks.length === 0)
    errors.push('requiredChecks must be non-empty');
  else
    artifact.requiredChecks.forEach((check, index) => {
      requireNonEmptyString(check?.kind, `requiredChecks[${index}].kind`, errors);
      requireNonEmptyString(check?.command, `requiredChecks[${index}].command`, errors);
      requireNonEmptyString(check?.outcome, `requiredChecks[${index}].outcome`, errors);
      requireNonEmptyString(check?.evidence, `requiredChecks[${index}].evidence`, errors);
    });
  if (
    Array.isArray(artifact?.requiredChecks) &&
    !artifact.requiredChecks.some((check) => check.kind === 'DETERMINISTIC')
  )
    errors.push('requiredChecks must distinguish at least one DETERMINISTIC check');

  for (const collection of [
    'queues',
    'findings',
    'assumptions',
    'remainingRisks',
    'modelUsage',
    'operatorGates'
  ]) {
    if (!Array.isArray(artifact?.[collection])) errors.push(`${collection} must be an array`);
  }
  for (const collection of ['assumptions', 'remainingRisks', 'modelUsage', 'operatorGates']) {
    if (Array.isArray(artifact?.[collection]) && artifact[collection].length === 0)
      errors.push(`${collection} must record a value or explicit NONE/NOT_APPLICABLE entry`);
  }
  (artifact?.queues ?? []).forEach((queue, index) => {
    for (const key of ['id', 'owner', 'status'])
      requireNonEmptyString(queue?.[key], `queues[${index}].${key}`, errors);
  });
  (artifact?.findings ?? []).forEach((finding, index) => {
    for (const key of ['id', 'severity', 'status', 'evidence'])
      requireNonEmptyString(finding?.[key], `findings[${index}].${key}`, errors);
  });
  (artifact?.modelUsage ?? []).forEach((usage, index) => {
    requireNonEmptyString(usage?.model, `modelUsage[${index}].model`, errors);
    requireNonEmptyString(usage?.role, `modelUsage[${index}].role`, errors);
    if (!Number.isInteger(usage?.turns) || usage.turns < 0)
      errors.push(`modelUsage[${index}].turns must be a non-negative integer`);
  });
  (artifact?.operatorGates ?? []).forEach((gate, index) => {
    for (const key of ['kind', 'outcome', 'evidence'])
      requireNonEmptyString(gate?.[key], `operatorGates[${index}].${key}`, errors);
  });
  for (const kind of ['MANUAL_VISUAL', 'MERGE_APPROVAL']) {
    if (!(artifact?.operatorGates ?? []).some((gate) => gate.kind === kind))
      errors.push(`operatorGates must record ${kind} as pending, approved, or not applicable`);
  }
  if (!Array.isArray(artifact?.paths?.inspected) || artifact.paths.inspected.length === 0)
    errors.push('paths.inspected must be non-empty');
  if (!Array.isArray(artifact?.paths?.changed)) errors.push('paths.changed must be an array');
  if (
    !artifact?.delegation ||
    !Number.isInteger(artifact.delegation.childCount) ||
    !Number.isInteger(artifact.delegation.delegatedTurnCount)
  )
    errors.push('delegation counts must be integers');
  if (artifact?.delegation?.childCount < 0 || artifact?.delegation?.delegatedTurnCount < 0)
    errors.push('delegation counts must be non-negative');
  if (typeof artifact?.delegation?.rootAgentTreeInspected !== 'boolean')
    errors.push('delegation.rootAgentTreeInspected must be boolean');
  for (const key of ['ledgerPath', 'ledgerStatus', 'descendantConfirmation'])
    requireNonEmptyString(artifact?.delegation?.[key], `delegation.${key}`, errors);

  return errors;
}

function validateReadiness(artifact) {
  const errors = [];
  if (!READY_STATES.has(artifact.state)) errors.push(`state ${artifact.state} is not ready`);
  if (artifact.reviewer?.independentFromPrimaryImplementation !== true)
    errors.push('reviewer is not independent from primary implementation');
  for (const [axis, result] of Object.entries(artifact.reviewAxes ?? {})) {
    if (result.status !== 'SATISFIED') errors.push(`${axis} review is ${result.status}`);
  }
  for (const row of artifact.acceptanceMatrix ?? []) {
    if (row.status !== 'SATISFIED') errors.push(`criterion is ${row.status}: ${row.criterion}`);
  }
  for (const check of artifact.requiredChecks ?? []) {
    if (!PASSING_CHECK_STATES.has(check.outcome))
      errors.push(`required check is ${check.outcome}: ${check.command}`);
  }
  for (const queue of artifact.queues ?? []) {
    if (CLOSED_QUEUE_STATES.has(queue.status)) continue;
    if (
      artifact.state === 'READY_FOR_OPERATOR' &&
      queue.owner === 'Operator' &&
      ['OPEN', 'PENDING'].includes(queue.status)
    )
      continue;
    errors.push(`queue item remains ${queue.status}: ${queue.id}`);
  }
  for (const finding of artifact.findings ?? []) {
    if (!RESOLVED_FINDING_STATES.has(finding.status))
      errors.push(`finding remains ${finding.status}: ${finding.id}`);
  }
  if (artifact.delegation?.ledgerStatus === 'VIOLATED')
    errors.push('delegation ledger is VIOLATED');
  if (artifact.delegation?.rootAgentTreeInspected !== true)
    errors.push('complete root agent tree was not inspected');
  if (!['CONFIRMED', 'NOT_APPLICABLE'].includes(artifact.delegation?.descendantConfirmation))
    errors.push('descendant confirmation is not decisive');
  if ((artifact.delegation?.childCount ?? 0) > 0) {
    if (
      artifact.delegation.ledgerPath === 'NOT_APPLICABLE' ||
      artifact.delegation.ledgerStatus === 'NOT_APPLICABLE'
    )
      errors.push('delegated work requires a ledger path and status');
    if (artifact.delegation.descendantConfirmation !== 'CONFIRMED')
      errors.push('delegated work requires descendantConfirmation=CONFIRMED');
  }
  if (artifact.state === 'ACCEPTANCE_COMPLETE') {
    for (const gate of artifact.operatorGates ?? []) {
      if (!['APPROVED', 'NOT_APPLICABLE'].includes(gate.outcome))
        errors.push(`ACCEPTANCE_COMPLETE requires operator gate resolution: ${gate.kind}`);
    }
  }
  return errors;
}

function compareIdentity(expected, actual) {
  const errors = [];
  for (const key of [
    'baseCommit',
    'headCommit',
    'aggregateDiffSha256',
    'stagedDiffSha256',
    'untrackedFilesSha256',
    'sourceArtifactsSha256',
    'policyArtifactsSha256'
  ]) {
    if (expected?.[key] !== actual[key]) errors.push(`stale tree identity: ${key} does not match`);
  }
  if (
    JSON.stringify(expected?.excludedMetadataPaths) !== JSON.stringify(actual.excludedMetadataPaths)
  )
    errors.push('stale tree identity: excludedMetadataPaths do not match');
  return errors;
}

function printUsage() {
  console.error(
    'Usage:\n  check-integration-review-readiness.mjs fingerprint --base SHA --source PATH --policy PATH [--exclude-metadata PATH]\n  check-integration-review-readiness.mjs check --artifact PATH [--allow-blocked]'
  );
}

function main() {
  try {
    const { command, values, allowBlocked } = parseArguments(process.argv.slice(2));
    const repoRoot = process.cwd();
    if (command === 'fingerprint') {
      const sourceArtifacts = many(values, 'source').map((entry) =>
        normalizeRepoPath(repoRoot, entry)
      );
      const policyArtifacts = many(values, 'policy').map((entry) =>
        normalizeRepoPath(repoRoot, entry)
      );
      const treeIdentity = buildTreeIdentity({
        repoRoot,
        baseCommit: one(values, 'base'),
        sourceArtifacts,
        policyArtifacts,
        excludedMetadataPaths: many(values, 'exclude-metadata')
      });
      console.log(JSON.stringify({ sourceArtifacts, policyArtifacts, treeIdentity }, null, 2));
      return;
    }
    if (command === 'check') {
      const artifactPath = normalizeRepoPath(repoRoot, one(values, 'artifact'));
      if (!artifactPath.startsWith('plans/agent-reviews/'))
        fail('review artifacts must live under plans/agent-reviews/');
      const artifact = JSON.parse(readFileSync(path.join(repoRoot, artifactPath), 'utf8'));
      const errors = validateArtifactShape(artifact);
      if (!artifact.treeIdentity?.excludedMetadataPaths?.includes(artifactPath))
        errors.push('treeIdentity.excludedMetadataPaths must include the review artifact itself');
      if (errors.length === 0) {
        const actual = buildTreeIdentity({
          repoRoot,
          baseCommit: artifact.treeIdentity.baseCommit,
          sourceArtifacts: artifact.sourceArtifacts,
          policyArtifacts: artifact.policyArtifacts,
          excludedMetadataPaths: artifact.treeIdentity.excludedMetadataPaths
        });
        errors.push(...compareIdentity(artifact.treeIdentity, actual));
      }
      if (!allowBlocked) errors.push(...validateReadiness(artifact));
      if (errors.length > 0) fail(errors.join('\n - '));
      console.log(
        `[integration-review] ${allowBlocked ? 'shape valid' : 'ready'}: ${artifact.taskId} (${artifact.state})`
      );
      return;
    }
    printUsage();
    process.exitCode = 2;
  } catch (error) {
    console.error(`[integration-review] failed\n - ${error.message}`);
    process.exitCode = 1;
  }
}

main();
