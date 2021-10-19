#! /bin/bash

# set -xv # Enable debugging till things get sorted out

MONGO_CONNECTION_STRING="mongodb+srv://${MCLI_USER}:${MCLI_PASSWD}@${MCLI_URL}?retryWrites=true&w=majority"
# NCORE=`nproc --all`
NCORE=16
OMP_NUM_THREADS=1

mongo_eval () {
  QRY=`mongo "${MONGO_CONNECTION_STRING}" --eval "${1}" --quiet`
  echo $QRY
  UPD=`echo $QRY | jq -r .matchedCount`
  # Pattern match required, as mongo returns multiple json objects when
  # connection is slow. 
  if [[ "$UPD" != *1* ]]; then
    echo "ERROR in mongoDB update"
  fi
}

updateAPIDB () {
  echo $1
  statusValue=0
  if [ "$1" == "completed" ]; then
    statusValue=1
  fi
  DATE_ISO=`date -Iseconds`
  CURLOUT=`curl --header "Content-Type: application/json" \
    --request POST \
    --data "{\"status\": ${statusValue}, \"date\": \"${DATE_ISO}\", \"key\":\"${API_KEY}\"}" \
    ${API_URL}`
  echo $CURLOUT
  CURLSTATUS=`echo $CURLOUT | jq -r .status`
  if [ "$CURLSTATUS" != 1 ]; then
    echo "ERROR in curl update of count API"
  fi
  mongo_eval "db.sensor_details.updateOne({job_id: \"${JOBID}\"}, {\$set: { simulation_status:\"${1}\", computed_time:\"${DATE_ISO}\", job_started_at:\"${2}\" } });"
}

updateMPSonMongo () {
  MONGOOUT=`mongo "${MONGO_CONNECTION_STRING}" --eval "db.mps_versus_time.updateOne({event_id: \"${EVENTID}\"}, {\\$set: { mps_time:\"${1}\", mps_value:\"${2}\" } });" --quiet`
  echo $MONGOOUT
  UPD=`echo $MONGOOUT | jq -r .matchedCount`
  # Pattern match required, as mongo returns multiple json objects when
  # connection is slow. 
  if [[ "$UPD" != *1* ]]; then
    echo "Event ID absent in mongoDB mps_versus_time collection; creating new entry"
    MONGOOUT=`mongo "${MONGO_CONNECTION_STRING}" --eval "db.mps_versus_time.insert({event_id: \"${EVENTID}\", mps_time:\"${1}\", mps_value:\"${2}\" });" --quiet`
    if [[ "$MONGOOUT" != *'"nInserted" : 1'* ]]; then
      echo "ERROR in mongoDB insert MPS"
    fi
  fi
}

updateCodeVersiononMongo () {
  MONGOOUT=`mongo "${MONGO_CONNECTION_STRING}" --eval "db.application_versions.updateOne({event_id: \"${EVENTID}\"}, {\\$set: { code_hash :\"${1}\",  code_branch :\"${2}\" } });" --quiet`
  echo $MONGOOUT
  UPD=`echo $MONGOOUT | jq -r .matchedCount`
  # Pattern match required, as mongo returns multiple json objects when
  # connection is slow. 
  if [[ "$UPD" != *1* ]]; then
    echo "Event ID absent in mongoDB application_version collection; creating new entry"
    MONGOOUT=`mongo "${MONGO_CONNECTION_STRING}" --eval "db.application_versions.insert({event_id: \"${EVENTID}\", code_hash :\"${1}\",  code_branch :\"${2}\" });" --quiet`
    if [[ "$MONGOOUT" != *'"nInserted" : 1'* ]]; then
      echo "ERROR in mongoDB insert Code Version"
    fi
  fi
}

function generate_simulation_for_player () {
  DATE_START=`date -Iseconds`
  aws s3 cp $1 sensor_data
  echo "Batch Index : $AWS_BATCH_JOB_ARRAY_INDEX"
  player_simulation_data=`cat sensor_data | jq -r .[$AWS_BATCH_JOB_ARRAY_INDEX]`
  simulation_data=`echo $player_simulation_data | jq -r .impact_data`
  ACCOUNTID=`echo $player_simulation_data | jq -r .account_id`
  USERCOGNITOID=`echo $player_simulation_data | jq -r .user_cognito_id`
  INDEX=`echo $player_simulation_data | jq -r .index`
  EVENTID=`echo $simulation_data | jq -r .event_id`
  JOBID=`echo $simulation_data | jq -r .job_id`
  MESHFILE=`echo $simulation_data | jq -r .simulation.mesh`
  MESHFILEROOT=`echo "$MESHFILE" | cut -f 1 -d '.'`
  MESHTYPE=`echo "$MESHFILEROOT" | cut -f 1 -d '_'`

  simulation_details=`echo $simulation_data | jq -r .simulation`

  WRITEPVDFLAG=`echo $simulation_details | jq -r '."write-vtu"'`
  # Set default value if field absent
  if [ "$WRITEPVDFLAG" == null ]; then
    WRITEPVDFLAG=true
  fi

  COMPUTEINJURYFLAG=`echo $simulation_details | jq -r '."compute-injury-criteria"'`
  # Set default value if field absent
  if [ "$COMPUTEINJURYFLAG" == null ]; then
    COMPUTEINJURYFLAG=true
  fi

  file_name=$EVENTID'_input.json'
  # Check whether player specific mesh exists
  CUSTOMMESH=`echo $player_simulation_data | jq -r .custom_mesh`
  if [ "$CUSTOMMESH" == yes ]; then
    # If custom mesh is yes, the code expects non-null mesh time stamp
    MESHTIMESTAMP=`echo $player_simulation_data | jq -r .mesh_timestamp`
    echo "Custom mesh time stamp used : $MESHTIMESTAMP"
    MESHNAME=${MESHTIMESTAMP}_${MESHTYPE}_mesh.inp
    echo "Fetching Mesh From : s3://$USERSBUCKET/$ACCOUNTID/profile/mesh/$MESHNAME"
    aws s3 cp s3://$USERSBUCKET/$ACCOUNTID/profile/mesh/$MESHNAME /home/ubuntu/FemTechRun/$MESHNAME

    # Update mesh name in json input file
    simulation_data=`echo $simulation_data | jq '.simulation.mesh = "'$MESHNAME'"'`
    MESHFILEROOT=`echo "$MESHNAME" | cut -f 1 -d '.'`
  else
    MESHNAME=$MESHTYPE'_brain.inp'
    echo "Fetching Mesh From : $DEFAULT_MESH_PATH/$MESHNAME"
    # Fetch player specific mesh from defaults
    aws s3 cp $DEFAULT_MESH_PATH/$MESHNAME /home/ubuntu/FemTechRun/$MESHNAME
  fi

  # Create player data directory
  mkdir -p /tmp/$ACCOUNTID
  # Writing player data to tmp directory
  echo $simulation_data > /tmp/$ACCOUNTID/$file_name

  # Choose the required executable
  FEMTECH_EXECUTABLE=ex5
  if [ echo $simulation_details | jq 'has("pressure")' ]; then
    FEMTECH_EXECUTABLE=ex21
  fi
  # Execute femtech
  cd /home/ubuntu/FemTechRun
  echo "Using $NCORE cores"
  mpirun -np $NCORE -mca btl_vader_single_copy_mechanism none ./$FEMTECH_EXECUTABLE /tmp/$ACCOUNTID/$file_name
  simulationSuccess=$?

  # Upload input file to S3
  aws s3 cp /tmp/$ACCOUNTID/$file_name s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/$file_name
  # Upload femtech log to S3 if it exists
  LOGFILE='femtech_'$EVENTID'.log'
  if test -f "$LOGFILE"; then
    aws s3 cp 'femtech_'$EVENTID'.log' s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/logs/'femtech_'$EVENTID'.log'
  fi

  if [ $simulationSuccess -eq 0 ]; then
      echo "Simulation completed successfully"

      python3 updateOutputJson.py /tmp/$ACCOUNTID/$file_name

      # Add EVENTID to output.json
      cat $EVENTID'_output.json'|jq '.event_id = "'$EVENTID'"' > /tmp/$ACCOUNTID/$EVENTID'_output.json'

      # Upload output files to S3
      aws s3 cp /tmp/$ACCOUNTID/$EVENTID'_output.json' s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/$EVENTID'_output.json'

      OutputFiles=( CSDM-3 CSDM-5 CSDM-10 CSDM-15 CSDM-30 MPS-95 )
      for name in "${OutputFiles[@]}"
      do
        aws s3 cp ${name}'.json' s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/${name}'.json'
      done

      # Upload MPS file to S3
      if test -f MPSfile.dat; then
        aws s3 cp MPSfile.dat s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/MPSfile.dat
      fi

      # Execute MergepolyData if injury metrics are computed
      if [ "$COMPUTEINJURYFLAG" = true ]; then
        xvfb-run -a ./MultipleViewPorts brain3.ply Br_color3.jpg $EVENTID'_output.json' $ACCOUNTID'_'$INDEX.png
        imageSuccess=$?
        if [ $imageSuccess -eq 0 ]; then
          # Upload file to S3
          aws s3 cp $ACCOUNTID'_'$INDEX.png s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/$EVENTID.png
        else
          echo "MultipleViewPorts returned ERROR code $imageSuccess"
          updateAPIDB "image_error" "${DATE_START}"
          return 1
        fi
      fi

      # Generate motion movie if VTU file is written in FemTecch
      if [ "$WRITEPVDFLAG" = true ]; then
        xvfb-run -a ./pvpython simulationMovie.py $MESHFILEROOT'_'$EVENTID
        videoSuccess_1=$?
        xvfb-run -a python3 addGraph.py /tmp/$ACCOUNTID/$file_name
        videoSuccess_2=$?
        if [ $videoSuccess_1 -eq 0 ] && [ $videoSuccess_2 -eq 0 ]; then
          # Generate movie with ffmpeg
          ffmpeg -y -an -r 5 -i 'updated_simulation_'$MESHFILEROOT'_'$EVENTID'.%04d.png' -vcodec libx264 -filter:v "crop=2192:1258:112:16" -profile:v baseline -level 3 -pix_fmt yuv420p 'simulation_'$EVENTID'.mp4'
          # Upload file to S3
          aws s3 cp 'simulation_'$EVENTID'.mp4' s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/movie/$EVENTID'.mp4'
        else
          echo "pvpython returned ERROR code $videoSuccess_1"
          updateAPIDB "video_error" "${DATE_START}"
          return 1
        fi
      fi

      # Generate injury mvoie if VTU file is written in FemTecch
      if [ "$WRITEPVDFLAG" = true ] && [ "$COMPUTEINJURYFLAG" = true ]; then
        xvfb-run -a ./pvpython mps95Movie.py  /tmp/$ACCOUNTID/$file_name
        videoSuccess=$?
        if [ $videoSuccess -eq 0 ]; then
          # Generate movie with ffmpeg
          ffmpeg -y -an -r 5 -i 'injury_'$EVENTID'.%04d.png' -vcodec libx264 -profile:v baseline -level 3 -pix_fmt yuv420p 'mps95_'$EVENTID'.mp4'
          # Upload file to S3
          aws s3 cp 'mps95_'$EVENTID'.mp4' s3://$USERSBUCKET/$ACCOUNTID/simulation/$EVENTID/movie/$EVENTID'_mps.mp4'
        else
          echo "pvpython returned ERROR code $videoSuccess"
          updateAPIDB "video_error" "${DATE_START}"
          return 1
        fi
      fi
      # Upload results details to db
      updateAPIDB "completed" "${DATE_START}"
      # uploadSuccess=$?
      # return $?
      mpsTime=`cat "${EVENTID}"_output.json | jq -r '.["principal-max-strain"]'.time`
      mpsValue=`cat "${EVENTID}"_output.json | jq -r '.["principal-max-strain"]'.value`
      updateMPSonMongo "${mpsTime}" "${mpsValue}"
      # Add code hash to a different table
      codeHashValue=`cat "${EVENTID}"_output.json | jq -r '.["code-version"]'`
      codeBranch=`cat "${EVENTID}"_output.json | jq -r '.["code-branch"]'`
      updateCodeVersiononMongo "${codeHashValue}" "${codeBranch}"
      # Trigger lambda for image generation
      curl --location --request GET 'https://cvsr9v6fz8.execute-api.us-east-1.amazonaws.com/Testlambda?account_id='$ACCOUNTID'&ftype=getSummary'
      curl --location --request GET 'https://cvsr9v6fz8.execute-api.us-east-1.amazonaws.com/Testlambda?account_id='$ACCOUNTID'&event_id='$EVENTID'&ftype=GetSingleEvent'
      curl --location --request GET 'https://cvsr9v6fz8.execute-api.us-east-1.amazonaws.com/Testlambda?account_id='$ACCOUNTID'&event_id='$EVENTID'&ftype=GetLabeledImage'
  else
    echo "FemTech returned ERROR code $simulationSuccess"
    updateAPIDB "femtech_error" "${DATE_START}"
    return 1
  fi
}
generate_simulation_for_player $1
