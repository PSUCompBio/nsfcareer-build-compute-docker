#! /bin/bash
function generate_simulation_for_player () {	
  aws s3 cp $1 sensor_data
  echo "$AWS_BATCH_JOB_ARRAY_INDEX"
  player_simulation_data=`cat sensor_data | jq -r .[$AWS_BATCH_JOB_ARRAY_INDEX]`
  simulation_data=`echo $player_simulation_data | jq -r .impact_data`
  PLAYERID=`echo $player_simulation_data | jq -r .player_id`
  INDEX=`echo $player_simulation_data | jq -r .index`
  IMAGEID=`echo $player_simulation_data | jq -r .image_id`
  IMAGETOKEN=`echo $player_simulation_data | jq -r .image_token`
  TOKENSECRET=`echo $player_simulation_data | jq -r .token_secret`
  IMPACT=`echo $player_simulation_data | jq -r .impact`
  OBJDATE=`echo $player_simulation_data | jq -r .date`
  UIDS=`echo $simulation_data | jq -r .uid`

  # Storing current timestamp in milliseconds
  time=`date +%s%3N`
  
  file_name='input_'$UIDS'.json'
  
  # Create player data directory
  mkdir -p /tmp/$PLAYERID
  # Writing player data to tmp directory
  echo $simulation_data > /tmp/$PLAYERID/$file_name

  # Execute femtech
  cd /home/ubuntu/FemTechRun
  mpirun -np 16 -mca btl_vader_single_copy_mechanism none ./ex5 /tmp/$PLAYERID/$file_name
  simulationSuccess=$?

  # Upload input file to S3
  aws s3 cp /tmp/$PLAYERID/$file_name s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/'input_'$UIDS'.json' 
  if [ $simulationSuccess -eq 0 ]; then
      echo "Simulation completed successfully"
      
      # Upload output file to S3
      aws s3 cp 'output_'$UIDS'.json' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/'output_'$UIDS'.json' 

      # Execute MergepolyData
      xvfb-run ./MultipleViewPorts brain3.ply Br_color3.jpg 'output_'$UIDS'.json' $PLAYERID$OBJDATE'_'$INDEX.png
      imageSuccess=$?
      xvfb-run ./pvpython simulationMovie.py $UID
      videoSuccess=$?
      if [ $imageSuccess -eq 0 ]; then
        # Upload file to S3
        aws s3 cp $PLAYERID$OBJDATE'_'$INDEX.png s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$time.png

        # Upload Image details to dynamodb
        aws dynamodb --region $REGION put-item --table-name 'simulation_images' --item "{\"image_id\":{\"S\":\"$IMAGEID\"},\"token\":{\"S\":\"$IMAGETOKEN\"},\"secret\": {\"S\":\"$TOKENSECRET\"},\"bucket_name\": {\"S\":\"$USERSBUCKET\"},\"path\":{\"S\":\"$PLAYERID/simulation/$OBJDATE/$IMAGEID/$time.png\"}, \"status\":{\"S\":\"completed\"},\"impact_number\":{\"S\": \"$IMPACT\"}, \"player_name\" : {\"S\": \"$PLAYERID\"}}"
      else
        echo "MultipleViewPorts returned ERROR code $imageSuccess"
      fi

      if [ $videoSuccess -eq 0 ]; then
        # Upload file to S3
        aws s3 cp 'simulation_'$UID'.avi' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$time.avi
      else
        echo "pvpython returned ERROR code $videoSuccess"
      fi

  else
    echo "FemTech returned ERROR code $simulationSuccess"
    # Upload output file to S3
    aws s3 cp 'femtech_'$UIDS'.log' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/logs/'femtech_'$UIDS'.log' 
  fi
}
generate_simulation_for_player $1
