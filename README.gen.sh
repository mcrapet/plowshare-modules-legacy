#!/bin/sh -e
#
# Copyright (c) 2016 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

target='README.md'
gen='./plowmodlist.py'
gen_opts='-f markdown'
template='README.template'
branch=master

if [ ! -f "$template" ]; then
    echo 'ERROR: Cannot find template file. Aborting.' >&2
    exit 1
fi
if [ ! -x "$gen" ]; then
    echo 'ERROR: Cannot find generator script. Aborting.' >&2
    exit 1
fi
if ! git rev-parse --is-inside-work-tree 1>/dev/null 2>&1; then
    echo 'ERROR: Not in a git repository. Abort.' >&2
    exit 1
fi

tmpfile=$(mktemp)
tmpdir=$(mktemp -d)
git archive $branch | tar -x -C $tmpdir
sed -ne '1,/=== BEGIN MATRIX ===/p' $template >$tmpfile
$gen $gen_opts $tmpdir | sed -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]|/|/g' >>$tmpfile
sed -ne '/=== END MATRIX ===/,$p' $template >>$tmpfile
cp $tmpfile $target
rm -rf $tmpfile $tmpdir
echo Done. Come back to $branch using:
echo "mv $target r.md && git checkout $branch && mv -f r.md $target"
