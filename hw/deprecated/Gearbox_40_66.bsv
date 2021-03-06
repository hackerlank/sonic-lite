
// Copyright (c) 2014 Cornell University.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package Gearbox_40_66;

import FIFO::*;
import BRAMFIFO::*;
import FIFOF::*;
import Clocks::*;
import SpecialFIFOs::*;
import GetPut::*;
import Vector::*;
import ClientServer::*;

import Connectable::*;
import Pipe::*;

interface Gearbox_40_66;
   interface PipeIn#(Bit#(40)) gbIn;
   interface PipeOut#(Bit#(66)) gbOut;
endinterface

(* synthesize *)
module mkGearbox40to66#(Clock clk_156_25)(Gearbox_40_66);

   let verbose = True;
   Clock defaultClock <- exposeCurrentClock;
   Reset defaultReset <- exposeCurrentReset;
   Reset rst_156_25 <- mkAsyncReset(2, defaultReset, clk_156_25);

   Reg#(Bit#(32)) cycle         <- mkReg(0);

   FIFOF#(Bit#(40)) fifo_in <- mkSizedFIFOF(2);
   Vector#(66, Reg#(Bit#(1))) sr0        <- replicateM(mkReg(0));
   Vector#(66, Reg#(Bit#(1))) sr1        <- replicateM(mkReg(0));
   FIFOF#(Bit#(66)) fifo_out <- mkFIFOF;

   SyncFIFOIfc#(Bit#(66)) synchronizer <- mkSyncBRAMFIFOFromCC(10, clk_156_25, rst_156_25);

   Reg#(Bit#(6)) state <- mkReg(0);
   Reg#(Int#(8)) sh_offset <- mkReg(0);
   Reg#(Int#(8)) sh_len    <- mkReg(0);
   Reg#(Bit#(1)) sh_use0   <- mkReg(0);
   Reg#(Bit#(1)) sh_use_sr <- mkReg(0);

   Wire#(Bit#(66)) dout_wires <- mkDWire(0);
   rule deqFifoOut;
      let v <- toGet(fifo_out).get;
      //dout_wires <= v;
      synchronizer.enq(v);//pack(dout_wires));
   endrule

//   rule enqSynchronizer;
//   endrule

   rule cyc;
      cycle <= cycle + 1;
   endrule

   rule state_machine;
      let value <- toGet(fifo_in).get;
      let next_state = state;
      let offset     = sh_offset;
      let len        = sh_len;
      let useSr0     = sh_use0;
      let updateSr   = sh_use_sr;

      case (state)
          32:      next_state = 0;
          default: next_state = next_state + 1;
      endcase

      if (offset + 40 >= 66) begin
         len = 66 - offset;
         useSr0 = True;
      end
      else begin
         len = 40;
         useSr0 = False;
      end

      offset = offset + 40;
      if (offset >= 66) begin
         offset = offset - 66;
      end

      if (len + sh_offset == 66) begin
         updateSr = True;
      end
      else begin
         updateSr = False;
      end

      Vector#(66, Bit#(1)) sr1_next = unpack(0);
      if (unpack(sh_use0)) begin
         sr1_next = readVReg(sr0);
         if(verbose) $display("%d: state %h, shift sr0 to sr1", cycle, state);
      end
      else begin
         sr1_next = readVReg(sr1);
         if(verbose) $display("%d: state %h, keep sr1", cycle, state);
      end

      function Bit#(1) value_sub(Integer i);
         Bit#(1) v = 0;
         if (fromInteger(i) < sh_offset) begin
            v = sr1_next[i];
         end
         else if (fromInteger(i) < sh_offset + len) begin
            v = value[fromInteger(i)-sh_offset];
         end
         else begin
            v = sr1_next[i];
         end
         return v;
      endfunction
      Vector#(66, Bit#(1)) next_sr1 = genWith(value_sub);
      writeVReg(take(sr1), next_sr1);

      function Bit#(1) value_sub_sr0(Integer i);
         Bit#(1) v;
         Int#(8) d_start = 40 - len;
         if (updateSr && fromInteger(i) < d_start) begin
            v = value[fromInteger(i) + len];
         end
         else begin
            v = 0;
         end
         return v;
      endfunction
      Vector#(66, Bit#(1)) next_sr0 = genWith(value_sub_sr0);
      writeVReg(take(sr0), next_sr0);

      if (verbose) $display("%d: state %h, curr_sr0=%h next_sr0=%h curr_sr1=%h next_sr1=%h sh_offset=%d len=%d use0=%d update=", cycle, state, pack(readVReg(sr0)), pack(next_sr0), pack(readVReg(sr1)), pack(next_sr1), sh_offset, len, sh_use0, updateSr);

      state     <= next_state;
      sh_offset <= offset;
      sh_len    <= len;
      sh_use0   <= pack(useSr0);
      sh_use_sr <= pack(updateSr);

      if (useSr0) begin
         fifo_out.enq(pack(next_sr1));
      end
   endrule

   interface gbIn = toPipeIn(fifo_in);
   interface gbOut = toPipeOut(synchronizer);//fifo_out);
endmodule

endpackage

//|State |     SR0 (66 bits)           |         SR1 (66 bits)         | Valid | Shift |
//    0    -----------------------------------------[39               0]    0       0
//    1    -------------------[13     0] [65     40][39               0]    1       1
//    2    -------------------------------------[53           14][13  0]    0       0
//    3    ----------------[27        0] [65:54][53           14][13  0]    1       1
//    4    ------------------------[1:0] [65          28][27          0]    1       1
//    5    ----------------------------------------[41           2][1:0]    0       0
//    6    ------------------[15      0] [65    42][41           2][1:0]    1       1
//    7    -------------------------------------[55          16][15   0]    0       0
//    8    -----------------[29       0] [65:56][55          16][15   0]    1       1
//    9    ------------------------[3:0] [65            30][29        0]    1       1
//   10    -------------------------------------[43          4][3     0]    0       0
//   11    --------------    [17      0] [65 44][43          4][3     0]    1       1
//   12    -------------------------------------[58       18][17      0]    0       0
//   13    ----------------[31        0] [65 58][57       18][17      0]    1       1
//   14    ----------------------- [5:0] [65            32][31        0]    1       1
//   15    --------------------------------------[45          6][5    0]    0       0
//   16    ------------------[19      0] [65  46][45          6][5    0]    1       1
//   17    -------------------------------------[59       20][19      0]    0       0
//   18    ----------------[33        0] [65  60][59      20][19      0]    1       1
//   19    ------------------------[7:0] [65        34][33            0]    1       1
//   20    -------------------------------------[47         8][7      0]    0       0
//   21    ------------------[21      0] [65   48][47       8][7      0]    1       1
//   22    ---------------------------------[61      22][21           0]    0       0
//   23    ------------[35            0] [65:62][61  22][21           0]    1       1
//   24    --------------------[9     0] [65      36][35              0]    1       1
//   25    -----------------------------------[49           10][9     0]    0       0
//   26    ------------------[23      0] [65   50][49       10][9     0]    1       1
//   27    ---------------------------------[63         24][23        0]    0       0
//   28    -----------[37             0] [65:64][63     24][23        0]    1       1
//   29    ---------------------[11   0] [65          38][37          0]    1       1
//   30    -----------------------------------[51         12][11      0]    0       0
//   31    ---------------[25         0] [65  52][51      12][11      0]    1       1
//   32    ------------------------------[65           26][25         0]    1       1

