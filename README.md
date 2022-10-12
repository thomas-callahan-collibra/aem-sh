# aem.sh

Single-file shell script for local AEM development on Apple M1. No other platform is tested.

This repo does not provide source AEM files. Fetch them from your Adobe dudes.

The script uses the `~/aem-sdk` directory, uses default ports 4502, 4503, sets corresponding JVM debugger ports at 45020, 45030, doubles the memory allocation, and has a bunch of pretty colors.


## Dependencies

The script does not manage dependencies. They are:

* Java JDK 11:
```
~ % java -version
java version "11.0.16" 2022-07-19 LTS
Java(TM) SE Runtime Environment 18.9 (build 11.0.16+11-LTS-199)
Java HotSpot(TM) 64-Bit Server VM 18.9 (build 11.0.16+11-LTS-199, mixed mode)
```
* [AEM as a Cloud Service SDK](https://experienceleague.adobe.com/docs/experience-manager-cloud-service/content/implementing/developing/aem-as-a-cloud-service-sdk.html?lang=en) - place the unzipped folder under `~/aem-sdk`
* `jq`
* `lsof`
* GNU versions of `sed` and `grep` - very important! Read how to install these with `brew` and set your `PATH` so that the brew executables are picked up first. To confirm:
```
~ % sed --version
sed (GNU sed) 4.8

~ % grep --version
grep (GNU grep) 3.7
```

Generally a good idea to stick to GNU and not the BSD versions of these utilities.


## Get started

* Clone this
* Create `~/bin` and in your profile `export $PATH=$PATH:~/bin`
* Create the symlink to `aem.sh`: `~/bin % ln -s ~/path/to/your/clone/aem-sh/aem.sh`
* Test with `aem help`

## Examples

### Create a local Author instance

```
aem create author
```

This is 

```
aem create publish
```

After these finish, check the status of the instances:


```
aem status
```

### Stop the instance

```
aem stop author
```

If you omit the instance type i.e. `aem stop`, the script attempts to process both types.

### Start the instance

```
aem start
```

will start both instances.

### Log the instance

```
aem log author
```

will tail the `error.log` file of the `author` instance. You can specify another parameter for another log file. For example, if you configured a `my-service.log` log file, `aem log author my-service`


### Destroy instances

```
aem destroy author
```

will prompt you for a confirmation, then stop the instance if it is running, then delete the folder.

### Restore content

Rather than committing paths and filenames to source, the script uses environment variables. Set them in your

```
# aem.sh
export AEM_PACKAGE_ASSETS=~/aem-sdk/content-collibra-assets.zip
export AEM_PACKAGE_ASSETS=~/aem-sdk/content-collibra.zip
```

Then run

```
aem restore_content author
```

on a fresh AEM instance, and the content is restored. DAM Workflows are disabled before installing, and re-enabled post-install.