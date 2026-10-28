# Fresh personal/workgroup target setup

This setup mode prepares a new empty installation to join an existing personal/workgroup cluster. The administrator obtains the existing cluster's public StoreID through the pairing flow. The pairing secret belongs to the enrollment flow and must not be passed to Setup as an argument, environment variable or receipt field. Raven, Stash, and Starlet now have live three-node membership on the current layout. After exactly one managed Starlet restart, independent status checks showed all three nodes ready with the same membership digest; each observed two connected data-capable peers, and normal content/history checks passed before and after restart. Use a build that reports the required commands and setup behavior; older public releases may differ. The target paths below describe the current layout.

On macOS, choose **Customize** in Installer and deselect **Initialize a sample store** before installing. This installs the software without creating a store; the Installer conclusion shows the installed executable path. On Debian, first install the complete package; dpkg owns `/opt/tractanda/current`. The current checkout uses `/Library/Tractanda/Stores` and `/Library/Tractanda/StoreIndices` on macOS, and `/opt/tractanda/var/lib/tractanda/Stores` and `/opt/tractanda/var/lib/tractanda/StoreIndices` on Linux. `/var/lib/tractanda` aliases the private data root; `/opt/tractanda/run/tractanda` aliases `/run/tractanda`. Older public releases may differ.

For a full-listener target, obtain the public StoreID from the inviter's `cluster status` output or the nonsecret invitation metadata. Create a nonsecret runtime file with this host's listener port and no initial peers, for example:

```json
{
  "profile": "tractanda.personal-runtime.v1",
  "settings": {
    "version": 1,
    "listen": {"host": "0.0.0.0", "port": 48732},
    "peers": [],
    "synchronization": {"enabled": true, "intervalSeconds": 15}
  }
}
```

Save the nonsecret file with restrictive permissions (`chmod 600 peer-runtime.json`). Run Setup as the existing OS user, using the matching installed helper:

```sh
sudo /Library/Tractanda/Software/current/bin/tractanda-setup install --name production --owner EXISTING_OS_USER --empty --fresh-personal-target --store-id STORE_ID --peer-runtime-configuration peer-runtime.json
```

On Debian, use `/opt/tractanda/current/bin/tractanda-setup`. This full-listener path deliberately omits `--new-instance-only` and `--outbound-peer-sync`. On macOS, it follows the software-only Installer choice above. After Setup, join with the code at the hidden prompt:

```sh
tractanda --profile production cluster join --hostname HOSTNAME
```

`HOSTNAME` is this node's stable DNS hostname. This ordinary join uses the already configured target and does not reconfigure Setup. The convenience command `cluster join --prepare-new production --hostname HOSTNAME` can prepare an empty outbound-only target automatically, but does not open a listener; current topology allows at most one outbound peer per node. For three-or-more-node meshes, use the full-listener procedure above. Existing or unrelated stores cannot be reset, adopted, or replaced by these commands.

Setup refuses paths belonging to an existing store, index, socket or unowned service definition. It creates the target with the selected StoreID, a new locally generated replica ID, no sample content and the configured external index. If Setup is interrupted, inspect its status and follow the recovery instruction for that exact local Setup transaction; do not delete content or reset identity. After Setup completes, ordinary `cluster join` uses the prepared target, and `cluster resume` continues an accepted enrollment operation. An existing standalone instance, including an apparently empty one, cannot be converted by this procedure. Investigate mismatched identities, custody or incomplete state rather than deleting content or resetting identity.

The new target is durably marked unjoined during initial activation. Ordinary content reads and writes remain fenced across restarts until the selected baseline has been completed through the join workflow. The local administrator can still inspect status and resume enrollment.

After Setup, the native enrollment workflow must authenticate and coordinate membership, validate and reconcile the cluster user and group configuration against the target's OS identities, and explicitly complete the selected-source baseline before reporting the target ready. Setup's initial local-owner policy is provisional and is not proof that the cluster user base is configured. A runtime-managed operational route or enrollment state must not alter Setup's listener policy, managed configuration file, service definition or receipt. Later membership operations use the daemon's authorized native interface, not repeated privileged installation. Recovery of canonical items and owned payloads remains governed by the personal/workgroup recovery contract; fresh cluster membership requires explicit pairing.
