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
  UUID=`echo $simulation_data | jq -r .uid`
  MESHFILE=`echo $simulation_data | jq -r .simulation.mesh`
  MESHFILEROOT=`echo "$MESHFILE" | cut -f 1 -d '.'`

  file_name=$UUID'_input.json'

  # Check whether player specific mesh exists
  MESH_EXISTS=`aws --region $REGION dynamodb get-item --table-name "users" --key "{\"user_cognito_id\" : {\"S\" :\"$PLAYERID\"}}" --attributes-to-get "is_selfie_inp_uploaded" --query "Item.is_selfie_inp_uploaded.BOOL"`
  echo "MESH EXISTS IS $MESH_EXISTS"
  null_case="null"
  if [ $MESH_EXISTS == $null_case ]; then
      # Fetch player specific mesh from defaults
      aws s3 cp $DEFAULT_MESH /home/ubuntu/FemTechRun/coarse_brain.inp
  else
      # Download player mesh
      mesh_name=`aws s3 ls $USERSBUCKET/$PLAYERID/profile/rbf/ | sort | tail -1 | awk '{print $4}'`
      echo "Mesh is $mesh_name"
      aws s3 cp s3://$USERSBUCKET/$PLAYERID/profile/rbf/$mesh_name /home/ubuntu/FemTechRun/$mesh_name

      # Update mesh name in simulation data
      simulation_data=`echo $simulation_data | jq '.simulation.mesh = "'$mesh_name'"'`

      echo "Updated simulation data is $simulation_data"
      MESHFILEROOT=`echo "$mesh_name" | cut -f 1 -d '.'`

  fi

  # Create player data directory
  mkdir -p /tmp/$PLAYERID
  # Writing player data to tmp directory
  echo $simulation_data > /tmp/$PLAYERID/$file_name

  # Execute femtech
  cd /home/ubuntu/FemTechRun
  mpirun -np 16 -mca btl_vader_single_copy_mechanism none ./ex5 /tmp/$PLAYERID/$file_name
  simulationSuccess=$?

  # Upload input file to S3
  aws s3 cp /tmp/$PLAYERID/$file_name s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$file_name
  # Upload femtech log to S3 if it exists
  LOGFILE='femtech_'$UUID'.log'
  if test -f "$LOGFILE"; then
    aws s3 cp 'femtech_'$UUID'.log' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/logs/'femtech_'$UUID'.log'
  fi

  if [ $simulationSuccess -eq 0 ]; then
      echo "Simulation completed successfully"

			python3 updateOutputJson.py $UUID'_output.json'

      # Upload output file to S3
      aws s3 cp $UUID'_output.json' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$UUID'_output.json'

      # Upload results details to dynamodb
      aws dynamodb --region $REGION update-item --table-name 'simulation_images' --key "{\"image_id\":{\"S\":\"$IMAGEID\"}}" --update-expression "set #token = :token, #secret = :secret, #bucket_name = :bucket_name, #root_path = :root_path, #status = :status, #impact_number = :impact_number, #player_name = :player_name" --expression-attribute-names "{\"#token\":\"token\",\"#secret\":\"secret\",\"#bucket_name\":\"bucket_name\",\"#root_path\":\"root_path\",\"#status\":\"status\",\"#impact_number\":\"impact_number\",\"#player_name\":\"player_name\"}" --expression-attribute-values "{\":token\":{\"S\":\"$IMAGETOKEN\"},\":secret\": {\"S\":\"$TOKENSECRET\"},\":bucket_name\": {\"S\":\"$USERSBUCKET\"},\":root_path\":{\"S\":\"$PLAYERID/simulation/$OBJDATE/$IMAGEID/\"}, \":status\":{\"S\":\"completed\"},\":impact_number\":{\"S\": \"$IMPACT\"}, \":player_name\" : {\"S\": \"$PLAYERID\"}}" --return-values ALL_NEW

      # Execute MergepolyData
      xvfb-run -a ./MultipleViewPorts brain3.ply Br_color3.jpg $UUID'_output.json' $PLAYERID$OBJDATE'_'$INDEX.png cellcentres.txt
      imageSuccess=$?
      xvfb-run -a ./pvpython simulationMovie.py $MESHFILEROOT'_'$UUID
      xvfb-run -a python3 addGraph.py /tmp/$PLAYERID/$file_name
      xvfb-run -a ./pvpython mps95Movie.py  /tmp/$PLAYERID/$file_name
      videoSuccess=$?
      if [ $imageSuccess -eq 0 ]; then
        # Upload file to S3
        aws s3 cp $PLAYERID$OBJDATE'_'$INDEX.png s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$IMAGEID.png
      else
        echo "MultipleViewPorts returned ERROR code $imageSuccess"
        aws dynamodb --region $REGION update-item --table-name 'simulation_images' --key "{\"image_id\":{\"S\":\"$IMAGEID\"}}" --update-expression "set #status = :status" --expression-attribute-names "{\"#status\":\"status\"}" --expression-attribute-values "{\":status\":{\"S\":\"image_error\"}}" --return-values ALL_NEW
      fi

      if [ $videoSuccess -eq 0 ]; then
        # Generate movie with ffmpeg
        ffmpeg -y -an -r 5 -i 'updated_simulation_'$MESHFILEROOT'_'$UUID'.%04d.png' -vcodec libx264 -filter:v "crop=2192:1258:112:16" -profile:v baseline -level 3 -pix_fmt yuv420p 'simulation_'$UUID'.mp4'
        # Upload file to S3
        aws s3 cp 'simulation_'$UUID'.mp4' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/movie/$IMAGEID'.mp4'
        # Generate movie with ffmpeg
        ffmpeg -y -an -r 5 -i 'injury_'$UUID'.%04d.png' -vcodec libx264 -profile:v baseline -level 3 -pix_fmt yuv420p 'mps95_'$UUID'.mp4'
        # Upload file to S3
        aws s3 cp 'mps95_'$UUID'.mp4' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/movie/$IMAGEID'_mps.mp4'
      else
        echo "pvpython returned ERROR code $videoSuccess"
        aws dynamodb --region $REGION update-item --table-name 'simulation_images' --key "{\"image_id\":{\"S\":\"$IMAGEID\"}}" --update-expression "set #status = :status" --expression-attribute-names "{\"#status\":\"status\"}" --expression-attribute-values "{\":status\":{\"S\":\"video_error\"}}" --return-values ALL_NEW
      fi
  else
    echo "FemTech returned ERROR code $simulationSuccess"
    aws dynamodb --region $REGION update-item --table-name 'simulation_images' --key "{\"image_id\":{\"S\":\"$IMAGEID\"}}" --update-expression "set #status = :status" --expression-attribute-names "{\"#status\":\"status\"}" --expression-attribute-values "{\":status\":{\"S\":\"error\"}}" --return-values ALL_NEW
  fi
}
generate_simulation_for_player $1
