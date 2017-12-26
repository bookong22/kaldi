// featbin/extract-segments.cc

// Copyright 2009-2011  Microsoft Corporation;  Govivace Inc.
//           2013       Arnab Ghoshal

// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
// WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
// MERCHANTABLITY OR NON-INFRINGEMENT.
// See the Apache 2 License for the specific language governing permissions and
// limitations under the License.

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "feat/wave-reader.h"

namespace kaldi {

/*
    This function concatenates several sets of feature vectors
    to form a longer set. The length of the output will be equal
    to the sum of lengths of the inputs but the dimension will be
    the same to the inputs.
*/

void ConcatFeats(const std::vector<Matrix<BaseFloat> > &in,
                 Matrix<BaseFloat> *out) {
  KALDI_ASSERT(in.size() >= 1);
  int32 tot_len = in[0].NumRows(),
      dim = in[0].NumCols();
  for (int32 i = 1; i < in.size(); i++) {
    KALDI_ASSERT(in[i].NumCols() == dim);
    tot_len += in[i].NumRows();
  }
  out->Resize(tot_len, dim);
  int32 len_offset = 0;
  for (int32 i = 0; i < in.size(); i++) {
    int32 this_len = in[i].NumRows();
    out->Range(len_offset, this_len, 0, dim).CopyFromMat(
        in[i]);
    len_offset += this_len;
  }
}

}

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    
    const char *usage =
        "Usage:  concat-segments [options] <feat-rspecifier> <segments-file> <feat-wspecifier>\n"
        "e.g. concat-segments scp:feats.scp segments ark:- | <some-other-program>\n"
        " segments-file format: each line is either\n"
        "<segment-id> <recording-id-1> <recording-id-2> <recording-id-3> ...\n"
        "e.g. tina-A tina-1 tina-2 tina-3 \n"
        "See also: extract-rows, extract-segments, paste-feats, which does the same thing but to feature files,\n";

    ParseOptions po(usage);
    
    bool binary = true;
    po.Register("binary", &binary, "If true, output files in binary "
                "(only relevant for single-file operation, i.e. no tables)");

    po.Read(argc, argv);

    if (po.NumArgs() < 2) {
      po.PrintUsage();
      exit(1);
    }

    std::string rspecifier = po.GetArg(1);
    std::string segments_rxfilename = po.GetArg(2);
    std::string wspecifier = po.GetArg(3);

    RandomAccessBaseFloatMatrixReader feat_reader(rspecifier);
    BaseFloatMatrixWriter feat_writer(wspecifier);
    Input ki(segments_rxfilename);  // no binary argment: never binary.

    int32 num_lines = 0, num_success = 0;

    std::string line;
    /* read each line from segments file */
    while (std::getline(ki.Stream(), line)) {
      num_lines++;
      std::vector<std::string> split_line;
      SplitStringToVector(line, " \t\r", true, &split_line);
      std::string utt = split_line[0];
      std::vector<Matrix<BaseFloat> > feats(split_line.size() - 1);
      //KALDI_LOG << "Num of segments " << split_line.size() - 1 ;
 
      for (int32 i = 0; i < split_line.size() - 1 ; i++) {
          feats[i] = feat_reader.Value(split_line[i + 1]);
      }
      Matrix<BaseFloat> output;
      ConcatFeats(feats, &output);
      feat_writer.Write(utt, output);
      num_success++;
    }
    KALDI_LOG << "Successfully processed " << num_success << " lines out of "
              << num_lines << " in the segments file. ";
    /* prints number of segments processed */
    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

