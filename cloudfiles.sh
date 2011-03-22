#! /bin/bash

# cloudfiles.sh
#
# Provides simple command-line access to Rackspace CloudFiles.
# Relies on curl and a few common Unix-y tools (file, basename, sed, tr, awk)
#
# Originally written by Mike Barton (mike@weirdlooking.com), based on work by letterj.
#
# Changes by Marcelo Martins:
#
#       02-10-2011  -   Added a file_upload function that also supports big files (5GB)
#
#       02-06-2011  -   Changed INFO to look for 404s      
#                   -   Added a new 404/INFO code check at end of script    
#
#       02-04-2011  -   Added INFO to set of commands     
#
#       01-30-2011  -   Added ability to auth against UK CloudFiles    
#                   -   Added double quotes to if/else blocks using single brackets
#                   -   Added -o /dev/null to the PUT/MKDIR/RM* scurl calls
#                   -   Added a container check function to make sure name starts with "/"
#                   -   Added some more verbose to error code checks
#

function usage {
  echo "Usage: $0 [Username] [API Key] LS"
  echo "       $0 [Username] [API Key] LS [container]"
  echo "       $0 [Username] [API Key] INFO [container] or [container]/[file]"
  echo "       $0 [Username] [API Key] PUT [container] [local file]"
  echo "       $0 [Username] [API Key] GET [/container/object]"
  echo "       $0 [Username] [API Key] MKDIR [/container]"
  echo "       $0 [Username] [API Key] RM [/container/object]"
  echo "       $0 [Username] [API Key] RMDIR [/container]"
  echo " "
  echo "      Note: "
  echo "           Prefix Username with \"REGION:\" for Europe use \"UK:\" and for North America use \"US:\" "
  echo "           eg: UK:joedoe , US:joedoe (US is optional since it's the default) " 
  echo " "
  exit 1
}

function scurl {
  curl -s -g -w '%{http_code}' -H Expect: -H "X-Auth-Token: $TOKEN" -X "$@"
}


function container_check {
  if [[ ! $1 =~ ^/ ]]; then
    echo -e "\n\t Error: container name must start with a \"/\" \n" 
    usage
  fi
}


function file_upload {

  CONTAINER=$1
  FILENAME=$2
  FILETYPE=`file -bi "$FILENAME"`
  OBJNAME=`basename "$FILENAME"`

  CURDIR=`pwd`                # The directory where the temporary splited files will reside
  CHUNKSIZE="4831838208"      # Size of each split chunk (4.5GB)
  SPLITSUFFIX=8                

  # Check that stat is GNU version or another like BSD (assumption)
  GNU=`stat --version 2>&1 | head -n 1  | awk '/GNU/'`
  if [ ! -z "$GNU" ]; then 
    FILESIZE=`stat -c%s $FILENAME | tr -d '\n\r' `
  else
    FILESIZE=`stat -f%z $FILENAME | tr -d '\n\r' `
  fi

  if [[ $? -eq 1 ]]; then 
    echo -e "\t Unable to obtain file size \n"
    exit 1
  fi 

  if [[ $FILESIZE -gt $CHUNKSIZE ]]; then
    if [ ! -d $CURDIR/cf-tmp ]; then 
      mkdir $CURDIR/cf-tmp
    fi 

    split -b $CHUNKSIZE -d -a $SPLITSUFFIX  $FILENAME $CURDIR/cf-tmp/
    SEGMENTS=`ls -1 $CURDIR/cf-tmp/*` 
    CONTAINER_SEG=$CONTAINER"_segments"

    for segment in $SEGMENTS; do 
      SEGFILE=`basename "$segment"`
      echo " Uploading file segment : $SEGFILE"
      curl -k -s -g -o /dev/null -H "X-Auth-Token: $TOKEN" -X PUT "$URL/$CONTAINER_SEG"
      sleep 1
      curl -k -s -g -o /dev/null -T "$segment" -H "X-Auth-Token: $TOKEN" -H "Transfer-Encoding: chunked" -X PUT "$URL/$CONTAINER_SEG/$OBJNAME/$SEGFILE"
    done

    echo " Uploading manifest file: $OBJNAME "
    CODE=`scurl PUT -o /dev/null -H "X-Object-Manifest: $CONTAINER_SEG/$OBJNAME/" --data-binary '' "$URL/$CONTAINER/$OBJNAME" `

  else 
    echo " Uploading file: $OBJNAME "
    CODE=`scurl PUT -o /dev/null -H "Content-Type: $FILETYPE" -T "$FILENAME" "$URL/$CONTAINER/$OBJNAME"`
  fi

  if [ -d $CURDIR/cf-tmp ]; then
    echo " Removing temporary directory & files "
    rm -rf  $CURDIR/cf-tmp
  fi   
}





if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  usage
else

  if [[ $1 =~ ^UK: ]]; then 
    AUTHURL="https://lon.auth.api.rackspacecloud.com/v1.0"
    USER=`echo $1 | sed 's/^UK://' | tr -d "\r\n"`
  elif [[ $1 =~ ^US: ]]; then 
    AUTHURL="https://auth.api.rackspacecloud.com/v1.0"
    USER=`echo $1 | sed 's/^US://' | tr -d "\r\n"`
  else  
    # Default is US 
    AUTHURL="https://auth.api.rackspacecloud.com/v1.0" 
    USER=$1
  fi

  LOGIN=`curl --dump-header - -s -H "X-Auth-User: $USER" -H "X-Auth-Key: $2" "$AUTHURL"`
  TOKEN=`echo "$LOGIN" | grep ^X-Auth-Token | sed 's/.*: //' | tr -d "\r\n"`
  URL=`echo "$LOGIN" | grep ^X-Storage-Url | sed 's/.*: //' | tr -d "\r\n"`

  if [ -z "$TOKEN" ] || [ -z "$URL" ]; then
    echo -e "\n\t Unable to authenticate \n"
    exit 1
  fi

  case "$3" in
    LS)
      if [ -z "$4" ]; then
        curl -s -o - -H "Expect:" -H "X-Auth-Token: $TOKEN" "$URL"
      else
        curl -s -o - -H "Expect:" -H "X-Auth-Token: $TOKEN" "$URL/$4"
      fi
      exit 0
      ;;
    GET)
      container_check $4 
      OBJNAME=`basename "$4"`
      CODE=`scurl GET "$URL$4" -o "$OBJNAME" `
      ;;
    PUT)
      if [ ! -f "$5" ]; then
        usage
      fi
      file_upload $4 $5
      ;;
    MKDIR)
      container_check $4 
      CODE=`scurl PUT "$URL$4" -T /dev/null -o /dev/null`
      ;;
    RM*) 
      container_check $4 
      CODE=`scurl DELETE "$URL$4" -o /dev/null`
      ;;
    INFO)
      if [ ! -z "$4" ]; then
      RESULTS=`curl -s -I -H "X-Auth-Token: $TOKEN" -X HEAD "$URL/$4" 2>&1`
      CODE_CHECK=`echo "$RESULTS" | head -n 1| awk '/404/'`
        if [ -z "$CODE_CHECK" ]; then 
          echo "$RESULTS" | awk '!/^HTTP/' 
          exit 0
        else
          CODE="404"
        fi
      fi
      ;;
    *) 
      usage
      ;;
  esac


  if [[ $CODE -lt 200 ]] || [[ $CODE -gt 299 ]]; then

    if [[ $CODE -eq 409 ]] && [[ $3 == "RMDIR" ]]; then
      echo -e "\n\t Error code ($CODE): Sorry ... Directory not empty \n"
    elif [[ $CODE -eq 404 ]] && [[ $3 == "RMDIR" ]]; then
      echo -e "\n\t Error code ($CODE): Sorry ... Directory not found \n"
    elif [[ $CODE -eq 404 ]] && [[ $3 == "RM" ]]; then
      echo -e "\n\t Error code ($CODE): Sorry ... File not found \n"
    elif [[ $CODE -eq 404 ]] && [[ $3 == "INFO" ]]; then
      echo -e "\n\t Error code ($CODE): Sorry ... File/Directory not found \n"
    else
      echo -e "\n\t Invalid response code: $CODE \n"
    fi 

    exit 1
  fi
fi

