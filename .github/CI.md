# Lepton CI

The `Lepton CI` workflow builds the compatibility tool, Android 11 and Android 14
root filesystems, the binder module, and test APKs. Each Android version runs its
own sysbake job and all 13 test shards.

## Runner setup

Register Linux self-hosted runners with the labels below. Docker must be available
to the runner service. The containers retain the distributions used by the
GitLab pipeline.

| Custom label | Architecture | Workload |
| --- | --- | --- |
| `x86_64-linux-kvm-docker` | X64 | Compatibility tool, rootfs packaging, and APK builds |
| `x86_64-linux-kvm-docker-largedisk` | X64 | Android rootfs builds |
| `aarch64-linux-docker-privileged` | ARM64 | Binder, sysbake, and test shards 1 through 12 |
| `aarch64-linux-docker-heavy-privileged` | ARM64 | Test shard 13 |

The ARM64 jobs run privileged containers and load a kernel module into the host.
Use isolated, disposable runner VMs with matching Debian Bookworm kernels and
available matching headers across both ARM64 pools. Each VM must start without
the binder module already loaded. Reusing a VM after a job can leave kernel and
mount state that breaks subsequent jobs. The large-disk pool must have enough
space for an Android source checkout, build output, and an additional uncompressed
artifact archive. Rootfs builds and test jobs retain their eight-hour job timeout.

## Repository secrets

Configure these Actions secrets before running the workflow.

| Secret | Purpose |
| --- | --- |
| `BUILD_TOKEN_USER` | The GitLab username authenticates submodules and Android source repositories. |
| `BUILD_TOKEN_PASSWORD` | The GitLab token grants read access to those repositories. |
| `CI_LEPTON_TOKEN` | The GitLab API token reads upstream rootfs jobs and artifacts. |
| `GITLAB_REGISTRY_USER` | The registry username authenticates private container pulls. |
| `GITLAB_REGISTRY_PASSWORD` | The registry token grants `read_registry` access. |

Git credentials are scoped to the fetch/build processes rather than written into
manifest URLs. GitLab remains the source for private images, submodules, and
reused rootfs artifacts. New build outputs are uploaded to GitHub Actions.

## Triggers and rootfs inputs

Pushes and same-repository pull requests run CI. A small hosted job skips branch
push builds when an open pull request already covers the branch. Fork pull
requests skip the privileged pipeline because they cannot access its secrets.
Maintainers can review and bring a trusted change onto a repository branch to
run the full pipeline. The workflow checks out the pull request head, matching
GitLab's source-branch pipeline behavior.

Manual runs accept `ROOTFS_VERSION` and `ROOTFS14_VERSION` independently.

| Input | Behavior |
| --- | --- |
| `latest` | The existing GitLab resolver selects a successful upstream release-tag rootfs job. |
| A branch or tag | The resolver downloads a successful upstream job for that ref. |
| An empty string | The workflow builds that rootfs from source. |

Automatic runs default to `latest`. Tags, pull requests, and `main` rebuild when
there is no previous release tag or when image sources or their build/dependency
scripts changed since that tag. GitHub checkout fetches full history and tags
for this comparison and for version stamping.

## Artifacts and local validation

Each job uploads a uniquely named artifact containing `ci-artifacts.tar`.
The shared download action restores original workspace paths and permissions.
Each test shard has its own artifact name. Rootfs, sysbake, and test jobs attempt
to upload diagnostics even when their main step fails. GitHub's artifact storage
retention policy applies to these outputs.

Run `actionlint .github/workflows/ci.yml`,
`shellcheck .ci_scripts/github-build-rootfs.sh`, and
`python3 .ci_scripts/test-github-ci.py` to validate the workflow locally.
The Python checks require PyYAML. Actual Android builds and privileged tests
require the runner pools, private registry access, and GitLab credentials above.

The original `.gitlab-ci.yml` remains available for the upstream GitLab pipeline.
