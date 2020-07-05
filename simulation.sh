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
  USERUID=`echo $simulation_data | jq -r .uid`
  MESHFILE=`echo $simulation_data | jq -r .simulation.mesh`
  MESHFILEROOT=`echo "$MESHFILE" | cut -f 1 -d '.'`

  # Storing current timestamp in milliseconds
  time=`date +%s%3N`

  file_name='input_'$USERUID'.json'

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
  aws s3 cp /tmp/$PLAYERID/$file_name s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/'input_'$USERUID'.json'
  if [ $simulationSuccess -eq 0 ]; then
      echo "Simulation completed successfully"

      # Upload output file to S3
      aws s3 cp 'output_'$USERUID'.json' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/'output_'$USERUID'.json'

      # Upload output_XYZ.json details to dynamodb
      aws dynamodb --region $REGION update-item --table-name 'simulation_images' --item "{\"image_id\":{\"S\":\"$IMAGEID\"},\"token\":{\"S\":\"$IMAGETOKEN\"},\"secret\": {\"S\":\"$TOKENSECRET\"},\"bucket_name\": {\"S\":\"$USERSBUCKET\"},\"path\":{\"S\":\"$PLAYERID/simulation/$OBJDATE/$IMAGEID/'output_'$USERUID'.json'\"}, \"status\":{\"S\":\"completed\"},\"impact_number\":{\"S\": \"$IMPACT\"}, \"player_name\" : {\"S\": \"$PLAYERID\"}}"

      # Execute MergepolyData
      xvfb-run -a ./MultipleViewPorts brain3.ply Br_color3.jpg 'output_'$USERUID'.json' $PLAYERID$OBJDATE'_'$INDEX.png cellcentres.txt
      imageSuccess=$?
      xvfb-run -a ./pvpython simulationMovie.py $MESHFILEROOT'_'$USERUID
      xvfb-run -a python3 addGraph.py /tmp/$PLAYERID/$file_name
      videoSuccess=$?
      if [ $imageSuccess -eq 0 ]; then
        # Upload file to S3
        aws s3 cp $PLAYERID$OBJDATE'_'$INDEX.png s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/$time.png

        # Upload Image details to dynamodb
        aws dynamodb --region $REGION update-item --table-name 'simulation_images' --item "{\"image_id\":{\"S\":\"$IMAGEID\"},\"token\":{\"S\":\"$IMAGETOKEN\"},\"secret\": {\"S\":\"$TOKENSECRET\"},\"bucket_name\": {\"S\":\"$USERSBUCKET\"},\"path\":{\"S\":\"$PLAYERID/simulation/$OBJDATE/$IMAGEID/$time.png\"}, \"status\":{\"S\":\"completed\"},\"impact_number\":{\"S\": \"$IMPACT\"}, \"player_name\" : {\"S\": \"$PLAYERID\"}}"
      else
        echo "MultipleViewPorts returned ERROR code $imageSuccess"
      fi

      if [ $videoSuccess -eq 0 ]; then
        # Generate movie with ffmpeg
        ffmpeg -y -an -r 5 -i 'updated_simulation_'$MESHFILEROOT'_'$USERUID'.%04d.png' -vcodec libx264 -filter:v "crop=2192:1258:112:16" -profile:v baseline -level 3 -pix_fmt yuv420p 'simulation_'$USERUID'.mp4'
        # Upload file to S3
        aws s3 cp 'simulation_'$USERUID'.mp4' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/movie/$time.mp4

        # Update movie file path for the simulation image
        aws dynamodb --region $REGION update-item --table-name 'simulation_images' --key "{\"image_id\":{\"S\":\"$IMAGEID\"}}" --update-expression "set movie_path = :path" --expression-attribute-values "{\":path\":{\"S\":\"$PLAYERID/simulation/$OBJDATE/$IMAGEID/movie/$time.mp4\"}}" --return-values ALL_NEW

      else
        echo "pvpython returned ERROR code $videoSuccess"
      fi

  else
    echo "FemTech returned ERROR code $simulationSuccess"

    # Upload output file to S3
    aws s3 cp 'femtech_'$USERUID'.log' s3://$USERSBUCKET/$PLAYERID/simulation/$OBJDATE/$IMAGEID/logs/'femtech_'$USERUID'.log'
  fi
}
generate_simulation_for_player $1
