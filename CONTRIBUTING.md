## How to contribute to Plowshare legacy modules

#### Foreword

This documentation is related to [Plowshare legacy modules](https://github.com/mcrapet/plowshare-modules-legacy), not [Plowshare core](https://github.com/mcrapet/plowshare).
Modules and core are separated in two different git repositories.

Plowshare without modules is worthless!

#### **How could you help us ?**

- [x] Report dead hosters
- [x] Report broken modules
- [x] Report misspellings, typos
- [x] Contribute to new modules (one hoster equal one plowshare module)

You may or may not provide a `.patch` depending your skills.

#### **How to submit a bug ?**

Before reporting issue, please ensure the following points:

* **Ensure the bug was not already reported** by searching on GitHub under [Issues](https://github.com/mcrapet/plowshare-modules-legacy/issues).
* Be sure to use the latest revision of [plowshare-modules-legacy](https://github.com/mcrapet/plowshare-modules-legacy).
* Try your download URL (or your file uploading) in a real browser (firefox, opera, etc). Upstream website can be temporary down.
* You IP might be blacklisted or in some rare case the service may not be available for your country. Try with a foreign HTTP proxy.

If you passed all checks above, [create a new issue](https://github.com/mcrapet/plowshare-modules-legacy/issues/new). Be sure to include **module name in title**.

Information to mention in issue content:
* Explain your issue as close as possible using english language.
* Attach full log (using `-v4` command line switch), see below.
* Anonymous, free account or premium account?
* Plowshare (core) version. For example: `v2.1.2`.

```
plowdown -v4 -r0 --no-plowsharerc --no-color <url> &>log.txt
```

```
plowup -v4 -r0 --no-plowsharerc --no-color <module> <filename> &>log.txt
```

*Attention*: Generated logs can contain your credentials (account login data specified with `-a` or `-b` command line switches).
Be sure to remove them before posting.

#### **How to submit a patch ?**

Before submitting your patch, check that your work complies with
[code policy](https://github.com/mcrapet/plowshare/wiki/Modules) (refer to last chapters).

If this is okay, you can create a [new pull request](https://github.com/mcrapet/plowshare-modules-legacy/pulls/).

Thanks!
