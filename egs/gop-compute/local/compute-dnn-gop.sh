#!/bin/bash

# Copyright 2016-2017  Author: Ming Tu
# Modified 2018  Author: Guanlong Zhao

nj=1 # number of parallel jobs
cmd=run.pl

echo "$0 $@"  # Print the command line for logging

[ -f path.sh ] && . ./path.sh # source the path.
. parse_options.sh || exit 1;

if [ $# != 4 ]; then
   echo "usage: local/compute-dnn-gop.sh <data-dir> <lm-dir> <am-dir> <gop-dir>"
   echo "e.g.:  local/compute-dnn-gop.sh data/speaker data/lm data/am exp/gop"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   exit 1;
fi

data=$1 # output of data_prep.sh
lang=$2 # language model dir
amdir=$3 # acoustic model dir
gopdir=$4 # output dir

for f in $data/text $lang/oov.int $amdir/tree $amdir/final.mdl $amdir/final.mat; do
  [ ! -f $f ] && echo "$0: expected file $f to exist" && exit 1;
done

oov=`cat $lang/oov.int` || exit 1;
mkdir -p $gopdir/log
echo $nj > $gopdir/num_jobs
splice_opts=`cat $amdir/splice_opts 2>/dev/null` # frame-splicing options.
cmvn_opts=`cat $amdir/cmvn_opts 2>/dev/null`

sdata=$data/split${nj}utt
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh --per-utt $data $nj || exit 1;

utils/lang/check_phones_compatible.sh $lang/phones.txt $amdir/phones.txt || exit 1;

# For the NN model I am using, it is LDA
echo "$0: feature type is lda"
feats="ark,s,cs:apply-cmvn --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $amdir/final.mat ark:- ark:- |"

echo "$0: computing GOP in $data using model from $amdir, putting results in $gopdir"
tra="ark:utils/sym2int.pl --map-oov $oov -f 2- $lang/words.txt $sdata/JOB/text|";
$cmd JOB=1:$nj $gopdir/log/gop.JOB.log \
  compute-dnn-gop --use-gpu=yes $amdir/tree $amdir/final.mdl $lang/L.fst "$feats" "$tra" "ark,t:$gopdir/gop.JOB" "ark,t:$gopdir/align.JOB" "ark,t:$gopdir/phoneme_ll.JOB" "ark,t:$gopdir/phonemes.JOB" || exit 1;

# Generate alignment
$cmd JOB=1:$nj $gopdir/log/align.JOB.log \
  linear-to-nbest "ark,t:$gopdir/align.JOB" "$tra" "" "" "ark:-" \| \
  lattice-align-words "$lang/phones/word_boundary.int" "$amdir/final.mdl" "ark:-" "ark,t:$gopdir/aligned.JOB" || exit 1;
$cmd JOB=1:$nj $gopdir/log/align_word.JOB.log \
  nbest-to-ctm "ark,t:$gopdir/aligned.JOB" "$gopdir/word.JOB.ctm"
$cmd JOB=1:$nj $gopdir/log/align_phone.JOB.log \
  lattice-to-phone-lattice "$amdir/final.mdl" "ark,t:$gopdir/aligned.JOB" "ark:-" \| \
  nbest-to-ctm "ark:-" "$gopdir/phone.JOB.ctm" || exit 1;

# Put all GOPs in the same file and move them together
for n in $(seq $nj); do
  cat $gopdir/gop.$n || exit 1;
done > $gopdir/gop.txt || exit 1
mkdir $gopdir/gop
mv $gopdir/gop.* $gopdir/gop

# Convert phonemes into human readable format
for part in $(seq $nj); do 
  utils/int2sym.pl -f 2- $amdir/phones.txt $gopdir/phonemes.$part > $gopdir/phonemes_sym.$part || exit 1;
done
mv $gopdir/phonemes_sym.* $gopdir/gop

python local/ctm2textgrid.py $nj $gopdir $gopdir/aligned_textgrid $lang/words.txt $lang/phones.txt $data/utt2dur

echo "$0: done computing GOP and generating alignments."
