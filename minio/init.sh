#!/bin/sh
# Runs in the minio-mc helper container: waits for MinIO, creates the shared bucket and the policies that Authelia groups map to
# (a signed-in person gets the policy named after their group: `users` and `admins`), then stays up so ops-bridge can run `mc`
# in it (s3.provision creates each person's bucket, quota and notebook key). Safe to run again.
set -e
export HOME=/tmp MC_CONFIG_DIR=/tmp/.mc
until mc ready local >/dev/null 2>&1; do sleep 2; done
mc mb --ignore-existing local/shared
mc admin policy create local users /init/policies/users.json
mc admin policy create local admins /init/policies/admins.json
echo "minio-mc: ready"
exec tail -f /dev/null
