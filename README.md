The goal of `aem.sh` is to promote a clean working development environment by making it easy to manage the lifecycle of local AEMaaCS instances: Author, Publish, and Web (Dispatcher).

## Dependencies

Ensure the following dependency requirements are met.

* [AEM as a Cloud Service SDK](https://experienceleague.adobe.com/docs/experience-manager-cloud-service/content/implementing/developing/aem-as-a-cloud-service-sdk.html?lang=en)
* Java JDK 11:
```
~ % java -version
java version "11.0.16" 2022-07-19 LTS
Java(TM) SE Runtime Environment 18.9 (build 11.0.16+11-LTS-199)
Java HotSpot(TM) 64-Bit Server VM 18.9 (build 11.0.16+11-LTS-199, mixed mode)
```
* `brew install jq`
* The GNU versions of `sed` and `grep` - see [this](https://medium.com/@bramblexu/install-gnu-sed-on-mac-os-and-set-it-as-default-7c17ef1b8f64) - and confirm with:
```
~ % sed --version
sed (GNU sed) 4.8

~ % grep --version
grep (GNU grep) 3.7
```

* Set the following two environment variables, e.g. in your `.zshrc`:
*
```
export AEM_PROJECT_HOME=~/git/my-aem-project                   # point to your AEM project
export AEM_PROJECT_HOME_PAGE=/content/my-co/us/en/home.html    # point to your AEM homepage
```



## Get started

1. Clone this repo
1. Create the `aem` symlink on your `$PATH`. A possible approach:
  * Create `~/bin` and in your profile: `export $PATH=$PATH:~/bin`
  * Create the symlink: `ln -s ~/path/to/your/clone/aem-sh/aem.sh ~/bin/aem`
1 Test with `aem help` to see the script's usage.
1. Create `~/aem-sdk`
1. Download the AEM SDK zip and unzip to `/aem-sdk/sdk`
1. Download your content packages from the source Author (typically Production), and please under `~/aem-sdk/packages` and is used by `aem install_content`
1. Optional: build your AEM project - the `all` artifact (zip file) is used by `aem install_code`



### Commands

#### Create

`aem create author` and `aem create publish` to create a local Author and Publish, respectively.

When creating the instance, the ootb `start` scripts are touched:

* sets the default AEM ports `4502` and `4503`,
* sets a JVM debugger at ports `45020` and `45030`,
* doubles the memory allocation,
* adds a `local` runmode.

#### Status

`aem status` will print the status of both instances


#### Stop

`aem stop author` will gracefully stop and shutdown the specified instance.


#### Start

`aem start author` will start the specified AEM instance, and wait until all the bundles are active.

`aem start web` will start the Docker container image running Apache Web Server and Dispatcher using the configs and rules under `$AEM_PROJECT_HOME/dispatcher/src`.

Then you can browse the site at `http://localhost:8080/`.  Make sure Docker Desktop and AEM Publisher are running


#### Log

`aem log publish` will tail the `error.log` file of the `publish` instance.

You can specify an additional argument for another log file. For example, if you configured a `my-service.log` log file, run `aem log publish my-service`.


#### Destroy

`aem destroy author` will prompt you for a confirmation, then forcefully stop the specified instance if running, and delete its home directory.


#### Install content

`aem install_content author` uploads and installs all the content packages stored under `~/aem-sdk/packages` to the specified instance.

DAM workflows are disabled before installing, and re-enabled post-install, to prevent ootb, expensive asset workflows from triggering.


#### Install code

`aem install_code publish` will look for the `all` build artifact under `$AEM_PROJECT_HOME/all/target` (this assumes the project was built) and upload and install it to the specified instance.


#### Provision

`aem provision author` is a shortcut command to `destroy`, `create`, `install_content, and `install_code` for the specified AEM type.

It will also hit the homepage defined at `$AEM_PROJECT_HOME_PAGE` a few times, and print the HTTP response code.


### Script notes

* For commands `start` `stop`, `status`, if you omit the instance type, i.e. `aem start`, the script will run the command for both instance types.
