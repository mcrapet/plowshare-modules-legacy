#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Copyright (c) 2016 Plowshare Team
# Released under the GNU Public License 3, see LICENSE file for details.
# vim: syntax=python sw=4 sts=4 et fenc=utf-8

"""
Plowshare modules lister.
"""

from __future__ import print_function
import sys
import argparse
import os
import re
import datetime

__version__ = '0.1'

class PlowshareModule(object):
    """
    Class describing a plowshare module (bash file)
    """

    def __variable_options(self, prefix, name):
        """Parse module variables (long and short switches).

           Returns:
             Dictionary with options variables.

           Raises:
             Exception: If module source is missing variable declaration.
        """
        ret = {}
        suffix = r'_OPTIONS=(?:"([^"]*)|$)'
        res = re.search(prefix + self._name_uppercase +
                        '_' + name + suffix, self._source_code, re.M)
        if not res:
            raise Exception('missing MODULE_{0}_{1}_OPTIONS definition'.format(
                self._name_uppercase, name))
        if res.group(1):
            for olist in res.group(1).strip().splitlines():
                tmp = olist.split(',', 4)
                 # Ex: 'AUTH' => ['a','auth','a=USER:PASSWORD','User account']
                ret[tmp[0]] = tmp[1:]
        return ret

    def __variable_auth(self, auth, auth_free=None):
        """ Returns: module credentials string """
        # 'User account (mandatory)'
        # 'User account'
        # 'Premium account'
        if auth:
            descr = auth[-1]
            if re.match('Premium', descr):
                ret = 'premium'
            else:
                ret = 'account'
            if re.match('Free', descr):
                raise Exception('wrong AUTH description for {} module'.format(self._name))
            if re.search('(mandatory)', descr):
                ret += ' (m)'
        # 'Free account'
        elif auth_free:
            descr = auth_free[-1]
            if not re.match('Free', descr):
                raise Exception('wrong AUTH_FREE description for {} module'.format(self._name))
            if auth:
                ret += '+free'
            else:
                ret = 'free'
            if re.search('(mandatory)', descr):
                ret += ' (m)'
        else:
            ret = 'anonymous'
        return ret

    # Boolean variables.
    # Ex: 'DOWNLOAD_RESUME=no' => false
    def __variable_bool(self, prefix, name):
        question = r'="?[YyEeSs]"?'
        res = re.search(prefix + self._name_uppercase +
                        '_' + name + question, self._source_code, re.M)
        return res != None

    def __init__(self, body, name=r'\w+'):
        self._source_code = body

        # Get module functions
        exp = re.findall(r'^(' + name + r')_(download|upload|delete|list|probe)\(\)',
                         self._source_code, re.M)
        if not exp:
            raise Exception('cannot find module exported functions')

        self._name = exp[0][0]
        self._has_download = 'download' in [e[1] for e in exp]
        self._has_upload = 'upload' in [e[1] for e in exp]
        self._has_delete = 'delete' in [e[1] for e in exp]
        self._has_probe = 'probe' in [e[1] for e in exp]
        self._has_list = 'list' in [e[1] for e in exp]

        # Sanity check: same module name for all functions
        if len(set([e[0] for e in exp])) != 1:
            raise Exception('not unique', self._name)

        # We assume that each module define this global variable
        # (even if this is only used by plowdown)
        res = re.search(r'^MODULE_(\w+)_REGEXP_URL=', self._source_code, re.M)
        if not res:
            raise Exception('cannot find uppercase name of ' + self._name)

        self._name_uppercase = res.group(1)

        prefix = r'^MODULE_'

        if self._has_download:
            self._download_options = self.__variable_options(prefix, 'DOWNLOAD')
            self._download_resume = self.__variable_bool(prefix, 'DOWNLOAD_RESUME')
            self._download_final_cookie = self.__variable_bool(prefix,
                                                               'DOWNLOAD_FINAL_LINK_NEEDS_COOKIE')
        if self._has_upload:
            self._upload_options = self.__variable_options(prefix, 'UPLOAD')
            self._upload_remote = self.__variable_bool(prefix, 'UPLOAD_REMOTE_SUPPORT')
        if self._has_delete:
            self._delete_options = self.__variable_options(prefix, 'DELETE')
        if self._has_list:
            self._list_options = self.__variable_options(prefix, 'LIST')
            self._list_subfolders = self.__variable_bool(prefix, 'LIST_HAS_SUBFOLDERS')
        if self._has_probe:
            self._probe_options = self.__variable_options(prefix, 'PROBE')
            # grep xxx_probe() function
            funcs = re.search('^' + self._name + r'_probe\(\).*?^}',
                              self._source_code, re.M | re.DOTALL)
            flags = re.findall(r'if \[\[ \$REQ_IN = \*([fhistv])\* \]\]; then',
                               funcs.group(0), re.M)
            self._probe_flags = sorted(flags + ['c'])

    @property
    def name(self):
        """ Returns: Module name string """
        return self._name

    @property
    def has_download(self):
        return self._has_download
    @property
    def download_final_cookie(self):
        """ Returns: Boolean. True if final url requires a cookie """
        return self._download_final_cookie
    @property
    def download_auth(self):
        if not self._has_download:
            return ''
        return self.__variable_auth(self._download_options.get('AUTH'),
                                    self._download_options.get('AUTH_FREE'))
    @property
    def download_opts(self):
        """ Returns: Module command line 'download' long options list """
        return ['--'+v[1] for v in self._download_options.values()]

    @property
    def has_upload(self):
        return self._has_upload
    @property
    def upload_remote_support(self):
        """ Returns: Boolean. True if remote upload is supported """
        return self._upload_remote
    @property
    def upload_auth(self):
        if not self._has_upload:
            return ''
        return self.__variable_auth(self._upload_options.get('AUTH'),
                                    self._upload_options.get('AUTH_FREE'))
    @property
    def upload_opts(self):
        """ Returns: Module command line 'upload' long options list """
        return ['--'+v[1] for v in self._upload_options.values()]

    @property
    def has_delete(self):
        return self._has_delete
    @property
    def delete_auth(self):
        if not self._has_delete:
            return ''
        return self.__variable_auth(self._delete_options.get('AUTH'),
                                    self._delete_options.get('AUTH_FREE'))
    @property
    def delete_opts(self):
        """ Returns: Module command line 'delete' long options list. """
        return ['--'+v[1] for v in self._delete_options.values()]

    @property
    def has_list(self):
        return self._has_list
    @property
    def list_auth(self):
        if not self._has_list:
            return ''
        return self.__variable_auth(self._list_options.get('AUTH'),
                                    self._list_options.get('AUTH_FREE'))

    @property
    def has_probe(self):
        return self._has_probe
    @property
    def probe_auth(self):
        if not self._has_probe:
            return ''
        return self.__variable_auth(self._probe_options.get('AUTH'),
                                    self._probe_options.get('AUTH_FREE'))
    @property
    def probe_flags(self):
        """ Returns: list of capabilities (characters) """
        return self._probe_flags

def warning(*items):
    print("WARNING:", *items, file=sys.stderr)

def iterate_modules(directory):
    config_file = os.path.join(directory, 'config')
    if not os.path.isfile(config_file):
        raise Exception('cannot open config file: ' + config_file)

    mod_list = []
    mod = re.compile(r'\w+\b', re.I)
    with open(config_file) as fd_conf:
        for i, line in enumerate(fd_conf, start=1):
            if not line.startswith('#'):
                res = mod.match(line)
                if res:
                    name = res.group(0)
                    module_file = os.path.join(directory, name + '.sh')
                    if os.path.isfile(module_file):
                        with open(module_file) as fd_module:
                            mod_list.append(PlowshareModule(fd_module.read(), name))
                    else:
                        warning('cannot open module file', module_file)
                else:
                    warning('cannot retrieve module name at line', i)
    return mod_list

def pretty_print_modules(modules, layout, bool_true='yes', bool_false='no'):
    for m in modules:
        # Build all possible fields
        fields = {}
        fields['m'] = m.name
        fields['down'] = bool_true if m.has_download else bool_false
        fields['up'] = bool_true if m.has_upload else bool_false
        fields['del'] = bool_true if m.has_delete else bool_false
        fields['list'] = bool_true if m.has_list else bool_false
        fields['probe'] = bool_true if m.has_probe else bool_false

        fields['down_opts'] = ''
        fields['down_final'] = ''
        if m.has_download:
            fields['down_auth'] = m.download_auth

            if m.download_final_cookie:
                fields['down_final'] = '(c)'

            if m.download_opts:
                fields['down_opts'] = '[`{}`]'.format(', '.join(m.download_opts)) # FIXME: Harcoded markdown syntax
        else:
            fields['down_auth'] = ''

        fields['up_opts'] = ''
        fields['up_remote'] = ''
        if m.has_upload:
            fields['up_auth'] = m.upload_auth
            if m.upload_remote_support:
                fields['up_remote'] = '(r)'

            if m.upload_opts:
                fields['up_opts'] = '[`{}`]'.format(', '.join(m.upload_opts)) # FIXME: Harcoded markdown syntax
        else:
            fields['up_auth'] = ''
        if m.has_delete:
            fields['del_auth'] = m.delete_auth
        else:
            fields['del_auth'] = ''
        if m.has_list:
            fields['list_auth'] = m.list_auth
        else:
            fields['list_auth'] = ''
        if m.has_probe:
            fields['probe_auth'] = m.probe_auth
            fields['probe_flags'] = ' '.join(m.probe_flags)
        else:
            fields['probe_auth'] = ''
            fields['probe_flags'] = ''

        print(layout.format(**fields))

# http://stackoverflow.com/questions/11415570/directory-path-types-with-argparse
class DirectoryType(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        prospective_dir = values
        if not os.path.isdir(prospective_dir):
            raise argparse.ArgumentTypeError(
                'readable_dir:{0} is not a valid path'.format(prospective_dir))
        if os.access(prospective_dir, os.R_OK):
            setattr(namespace, self.dest, prospective_dir)
        else:
            raise argparse.ArgumentTypeError(
                'readable_dir:{0} is not a readable dir'.format(prospective_dir))

if __name__ == '__main__':
    parser = argparse.ArgumentParser( \
            description='Plowshare module lister.')
    parser.add_argument('--version', action='version', version=__version__)
    parser.add_argument('-f', '--format', choices=['text', 'markdown'],
                        default='text', help='output results format (default: %(default)s)')
    parser.add_argument('DIRECTORY', action=DirectoryType, default=os.environ['PWD'], nargs='?',
                        help='Directory to find config file (default: current directory)')

    try:
        args = parser.parse_args()
        objs = iterate_modules(args.DIRECTORY)

        if args.format == 'text':
            pretty_print_modules(objs,
                                 '{m:18}|{down_auth:^13}|{up_auth:^13}|{del_auth:^13}|{list:^5}|{probe_flags:^10}|')
        elif args.format == 'markdown':
            print('&nbsp;|plowdown|plowup|plowdel|plowlist|plowprobe')
            print('---|---|---|:---:|:---:|---')
            pretty_print_modules(objs,
                                 '{m}|{down_auth} {down_final} {down_opts}|{up_auth} {up_remote} {up_opts}|{del}|{list}|{probe_flags}', 'x', '')
            print('(last update of this table: {0:%Y-%m-%d}; number of modules/supported hosters: {1})'.format(
                datetime.datetime.now(), len(objs)))

    except IOError, msg:
        parser.error(str(msg))
        sys.exit(0)
