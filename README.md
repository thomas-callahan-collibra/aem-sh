# aem.sh

Single-file shell script for local AEM development on Apple M1. No other platform is tested.

This repo does not provide source AEM files. Fetch them from your Adobe dudes.

The script uses the `~/aem-sdk` directory, uses default ports 4502, 4503, sets corresponding JVM debugger ports at 45020, 45030, doubles the memory allocation, and has a bunch of pretty colors.


## Get started

* Clone this repo
* Create `~/bin` and in your profile `export $PATH=$PATH:~/bin`
* Create the symlink to `aem.sh`: `~/bin % ln -s ~/path/to/your/clone/aem-sh/aem.sh`
* Test that `aem help` gives you usage


## Examples

### Create a local Author instance

```
aem create author
```

```
aem create publish
```

After these finish, check the status


```
aem status
```

### Stop the instance

```
aem stop author
```

If you omit the instance type (`author` or `publish`), the script attempts to process both types.

### Start the instance

```
aem start
```

will start both instances.


#### Environment variables

Rather than committing paths and filenames to source, the script uses environment variables. Set them in your

```
# aem.sh
export AEM_PACKAGE_ASSETS=~/aem-sdk/content-collibra-assets.zip
export AEM_PACKAGE_ASSETS=~/aem-sdk/content-collibra.zip
```