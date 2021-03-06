#!/bin/sh
set -e
cd ..
SXDIR=../../sx
PREFIX=`pwd`/test-libres3
$PREFIX/sbin/libres3_ocsigen --stop || true

if true; then
make distclean
rm -rf "$PREFIX"
mkdir "$PREFIX"
./configure --prefix="$PREFIX" --enable-tests --disable-docs --override ocamlbuildflags '-j\ 0'
make

. ./setup.data
cleanup() {
    echo "Killing libres3_ocsigen"
    $sbindir/libres3_ocsigen --stop
}
trap cleanup INT TERM EXIT
echo "Starting SX"
(cd $SXDIR/server && N=1 test/start-nginx.sh)
else
. ./setup.data
fi

echo
echo "Installing ocsigen"
make reinstall
$sbindir/libres3_ocsigen --version
echo "Configuring ocsigen"
$sbindir/libres3_setup --no-ssl --s3-host libres3.skylable.com --s3-http-port 8008 --default-volume-size 100G --default-replica 1 --sxsetup-conf $SXDIR/server/test-sx/1/etc/sxserver/sxsetup.conf --batch
echo "list_cache_expires=0." >>$sysconfdir/libres3/libres3.conf
$sbindir/libres3_ocsigen
echo "Running tests"
cd testsuite
./run-test.sh $sysconfdir/libres3/libres3-insecure.sample.s3cfg 2>&1 | tee sx.log
echo "OK"
