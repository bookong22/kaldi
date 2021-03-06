#!/bin/bash

###########################################################################################
# This script was copied from egs/fisher_swbd/s5/local/nnet3/run_ivector_common.sh
# The source commit was e69198c3dc5633f98eb88e1cdf20b2521a598f21
# Changes made:
#  - Modified paths to match multi_en naming conventions
###########################################################################################

. ./cmd.sh
set -e
stage=1
train_stage=-10
generate_alignments=true # false if doing chain training
speed_perturb=true
multi=multi_a

. ./path.sh
. ./utils/parse_options.sh

# perturbed data preparation
train_set=$multi/tdnn
if [ "$speed_perturb" == "true" ]; then
  if [ $stage -le 1 ]; then
    #Although the nnet will be trained by high resolution data, we still have to perturbe the normal data to get the alignment
    # _sp stands for speed-perturbed

    for datadir in $multi/tdnn; do
      utils/perturb_data_dir_speed.sh 0.9 data/${datadir} data/temp1
      utils/perturb_data_dir_speed.sh 1.1 data/${datadir} data/temp2
      utils/combine_data.sh data/${datadir}_tmp data/temp1 data/temp2
      utils/validate_data_dir.sh --no-feats data/${datadir}_tmp
      rm -r data/temp1 data/temp2

      steps/make_mfcc.sh --cmd "$train_cmd" --nj 50 \
        data/${datadir}_tmp exp/make_mfcc/${datadir}_tmp || exit 1;
      steps/compute_cmvn_stats.sh data/${datadir}_tmp exp/make_mfcc/${datadir}_tmp || exit 1;
      utils/fix_data_dir.sh data/${datadir}_tmp

      utils/copy_data_dir.sh --spk-prefix sp1.0- --utt-prefix sp1.0- data/${datadir} data/temp0
      utils/combine_data.sh data/${datadir}_sp data/${datadir}_tmp data/temp0
      utils/fix_data_dir.sh data/${datadir}_sp
      rm -r data/temp0 data/${datadir}_tmp
    done
  fi

  if [ $stage -le 2 ] && [ "$generate_alignments" == "true" ]; then
    #obtain the alignment of the perturbed data
    steps/align_fmllr.sh --nj 100 --cmd "$train_cmd" \
      data/$multi/tdnn_sp data/lang exp/$multi/tri5 exp/$multi/tri5_ali_sp || exit 1
  fi
  train_set=$multi/tdnn_sp
fi

if [ $stage -le 3 ]; then
  # the 100k_nodup directory is copied seperately, as
  # we want to use exp/tri1b_ali_100k_nodup for lda_mllt training
  # the main train directory might be speed_perturbed
  for dataset in $train_set $multi/tdnn_100k; do
    utils/copy_data_dir.sh data/$dataset data/${dataset}_hires

    # scale the waveforms, this is useful as we don't use CMVN
    data_dir=data/${dataset}_hires
    cat $data_dir/wav.scp | python -c "
import sys, os, subprocess, re, random
scale_low = 1.0/8
scale_high = 2.0
for line in sys.stdin.readlines():
  if len(line.strip()) == 0:
    continue
  print '{0} sox --vol {1} -t wav - -t wav - |'.format(line.strip(), random.uniform(scale_low, scale_high))
"| sort -k1,1 -u  > $data_dir/wav.scp_scaled || exit 1;
    mv $data_dir/wav.scp_scaled $data_dir/wav.scp

    steps/make_mfcc.sh --nj 70 --mfcc-config conf/mfcc_hires.conf --cmd "$train_cmd" \
      data/${dataset}_hires exp/make_hires/$dataset;
    steps/compute_cmvn_stats.sh data/${dataset}_hires exp/make_hires/${dataset};

    # Remove the small number of utterances that couldn't be extracted for some
    # reason (e.g. too short; no such file).
    utils/fix_data_dir.sh data/${dataset}_hires;
  done

  for dataset in eval2000 rt03; do
    # Create MFCCs for the eval set
    utils/copy_data_dir.sh data/$dataset/test data/${dataset}_hires/test
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 10 --mfcc-config conf/mfcc_hires.conf \
        data/${dataset}_hires/test exp/make_hires/$dataset;
    steps/compute_cmvn_stats.sh data/${dataset}_hires/test exp/make_hires/$dataset;
    utils/fix_data_dir.sh data/${dataset}_hires/test  # remove segments with problems
  done

  # Take the first 30k utterances, which will be used for the diagubm training
  utils/subset_data_dir.sh --first data/${train_set}_hires 30000 data/${train_set}_30k_hires
  utils/data/remove_dup_utts.sh 200 data/${train_set}_30k_hires data/${train_set}_30k_nodup_hires
fi

# ivector extractor training
if [ $stage -le 5 ]; then
  # We need to build a small system just because we need the LDA+MLLT transform
  # to train the diag-UBM on top of.  We use --num-iters 13 because after we get
  # the transform (12th iter is the last), any further training is pointless.
  # this decision is based on fisher_english
  steps/train_lda_mllt.sh --cmd "$train_cmd" --num-iters 13 \
    --splice-opts "--left-context=3 --right-context=3" \
    5500 90000 data/$multi/tdnn_100k_hires \
    data/lang exp/$multi/tri4_ali exp/$multi/nnet3/tri2b
fi

if [ $stage -le 6 ]; then
  # To train a diagonal UBM we don't need very much data, so use the smallest subset.
  steps/online/nnet2/train_diag_ubm.sh --cmd "$train_cmd" --nj 30 --num-frames 200000 \
    data/${train_set}_30k_nodup_hires 512 exp/$multi/nnet3/tri2b exp/$multi/nnet3/diag_ubm
fi

if [ $stage -le 7 ]; then
  # iVector extractors can be sensitive to the amount of data, but this one has a
  # fairly small dim (defaults to 100) so we don't use all of it, we use just the
  # 100k subset (just under half the data).
  steps/online/nnet2/train_ivector_extractor.sh --cmd "$train_cmd" --nj 10 \
    data/$multi/tdnn_100k_hires exp/$multi/nnet3/diag_ubm exp/$multi/nnet3/extractor || exit 1;
fi

if [ $stage -le 8 ]; then
  # We extract iVectors on all the train_nodup data, which will be what we
  # train the system on.

  # having a larger number of speakers is helpful for generalization, and to
  # handle per-utterance decoding well (iVector starts at zero).
  steps/online/nnet2/copy_data_dir.sh --utts-per-spk-max 2 data/${train_set}_hires data/${train_set}_max2_hires

  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 30 \
    data/${train_set}_max2_hires exp/$multi/nnet3/extractor exp/$multi/nnet3/ivectors_$train_set || exit 1;

  for data_set in eval2000 rt03; do
    steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 30 \
      data/${data_set}_hires/test exp/$multi/nnet3/extractor exp/$multi/nnet3/ivectors_$data_set || exit 1;
  done
fi

exit 0;
