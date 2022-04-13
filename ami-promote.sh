#!/bin/sh

# ami-promoter will run when a PR is merged into the repo.  it will find the most
# recent AMI that was built from that PR, and add a version tag to it
# If multiple AMIs were built from multiple commits within a single PR, only the last
# AMI built will have the version tags added

# our AMIs account only uses us-east-1
export AWS_DEFAULT_REGION="us-east-1"

# we presume to be running this against the master branch immediately after a PR merge has occurred.  find the
# second-to-last commit to master to use as our "stop" point.  we won't consider any AMIs on or before that
# point, since they came from a branch other than what was recently merged into master.  note that using
# "head -n 2" gives us two commits to master:
# 1 - the most recent merge commit to master from github.  we care about the commits that happened
# as a part of this merge commit. (we'll call this previous merge to master)
# 2 - the second-to-last merge commit to master from github.  we don't care about this merge, and we
# must ignore any AMIs in this merge, as they've already been promoted. (we'll call this
# previous-previous merge to master)
previous_previous_merge_to_master=$(git log --format=oneline --merges --first-parent master | head -n 2 | tail -n 1 | cut -f1 -d' ')
echo "found previous_previous merge to master $previous_previous_merge_to_master"

for sha in `git log --format=oneline | cut -f1 -d' '`; do

  echo "Investigating sha $sha."

  if [ $sha == $previous_previous_merge_to_master ]; then
    # at this point, we've looped through all commits in the previous PR
    echo "No commits in previous PR produced AMIs.  nothing to do..."
    break
  fi

  # AMIs are tagged with SHA from which they were built.  get all AMIs tagged with the SHA under consideration
  ami_list=""
  # This inherently assumes that for all packer build types we create AMIs in these regions.
  regions="us-east-1 us-west-2 eu-west-1 ap-southeast-2 ap-southeast-1 eu-central-1"
  for region in $regions
  do
    amis=$(aws ec2 describe-images --region $region --filters "Name=tag-key,Values=source_commit" "Name=tag-value,Values=$sha" | jq -r ".Images[].ImageId" 2> /dev/null)
    ami_list=$(echo $ami_list$amis | sed 's/$/ /')
  done

  if [ -z "$(echo $ami_list | sed 's/ //')" ]; then
    echo "Commit $sha produced no AMIs.  Skipping..."
    continue
  fi

  # we've found an AMIs to modify
  echo "Commit $sha produced AMIs:$ami_list"

  increment=`expr $(echo $ami_list | wc -w) / $(echo $regions | wc -w)`
  start=1
  end=$increment
  for region in $regions
  do
    for ami in $(echo $ami_list | cut -d ' ' -f$(echo `seq $start $end` | sed 's/ /,/g'))
    do

      ami_type=$(aws ec2 describe-tags --region $region --filters "Name=resource-id,Values=$ami"  | jq  '.Tags[]|select(.Key=="workflow").Value')

      echo "ami found $ami in $region for type $ami_type."

      echo "Writing version tag $1 to $ami in $region for type $ami_type."
      aws ec2 create-tags --region $region --resources $ami --tags Key=version,Value=$1

    done
    start=`expr $start + $increment`
    end=`expr $end + $increment`
  done && break # break terminates parent "for sha in" loop; once we promote, we're done
done

echo "done"