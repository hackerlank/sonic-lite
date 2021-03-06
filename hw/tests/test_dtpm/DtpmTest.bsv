import FIFO::*;
import FIFOF::*;
import Vector::*;
import BuildVector::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import ConnectalConfig::*;
import DefaultValue::*;

import Pipe::*;
import MemTypes::*;
import MemReadEngine::*;
import HostInterface::*;

import Dtpm::*;

//import "BDPI" function Action loadByteStream();

interface DtpmTestRequest;
   method Action startDtpm(Bit#(32) pointer, Bit#(32) numWords, Bit#(32) burstLen, Bit#(32) iterCount);
endinterface

interface DtpmTest;
   interface DtpmTestRequest request;
   interface Vector#(1, MemReadClient#(DataBusWidth)) dmaClient;
endinterface

interface DtpmTestIndication;
   method Action dtpTestDone(Bit#(32) matchCount);
endinterface

typedef 20 Delay; //one-way delay
Integer delay = valueOf(Delay);

module mkDtpmTest#(DtpmTestIndication indication) (DtpmTest);

   let verbose = False;

   Reg#(SGLId)    pointer  <- mkReg(0);
   Reg#(Bit#(32)) numWords <- mkReg(0);
   Reg#(Bit#(32)) burstLen <- mkReg(0);
   Reg#(Bit#(32)) toStart  <- mkReg(0);
   Reg#(Bit#(32)) toFinish <- mkReg(0);
   Reg#(Bit#(32)) cycle <- mkReg(0);
   FIFO#(void)          cf <- mkSizedFIFO(1);
   Bit#(MemOffsetSize) chunk = extend(numWords)*4;
   FIFOF#(Bit#(66)) write_encoder_data1 <- mkFIFOF;
   FIFOF#(Bit#(66)) write_encoder_data2 <- mkFIFOF;

   PipeOut#(Bit#(66)) pipe_encoder_out1 = toPipeOut(write_encoder_data1);
   PipeOut#(Bit#(66)) pipe_encoder_out2 = toPipeOut(write_encoder_data2);

   MemReadEngine#(128, 128, 2, 1) re <- mkMemReadEngine;

   Vector#(Delay, FIFOF#(Bit#(66))) fifo_sc1_to_sc2 <- replicateM(mkFIFOF);
   Vector#(Delay, FIFOF#(Bit#(66))) fifo_sc2_to_sc1 <- replicateM(mkFIFOF);

   PipeOut#(Bit#(66)) pipe_decoder_out1 = toPipeOut(fifo_sc1_to_sc2[delay-1]);
   PipeOut#(Bit#(66)) pipe_decoder_out2 = toPipeOut(fifo_sc2_to_sc1[delay-1]);

   Dtpm sc1 <- mkDtpm(1, 0);
   Dtpm sc2 <- mkDtpm(2, 0);

   mkConnection(pipe_encoder_out1, sc1.dtpTxIn);
   mkConnection(pipe_encoder_out2, sc2.dtpTxIn);
   mkConnection(pipe_decoder_out1, sc2.dtpRxIn);
   mkConnection(pipe_decoder_out2, sc1.dtpRxIn);

   rule tx1;
      let sc1_out <- toGet(sc1.dtpTxOut).get;
      fifo_sc1_to_sc2[0].enq(sc1_out);
      if(verbose) $display("%d: sc0 -> sc1 : %h", cycle, sc1_out);
   endrule

   rule tx2;
      let sc2_out <- toGet(sc2.dtpTxOut).get;
      fifo_sc2_to_sc1[0].enq(sc2_out);
      if(verbose) $display("%d: sc1 -> sc0 : %h", cycle, sc2_out);
   endrule

   rule every1;
      sc1.rx_ready(True);
      sc1.tx_ready(True);
      sc2.rx_ready(True);
      sc2.tx_ready(True);
      sc1.bsync_lock(True);
      sc2.bsync_lock(True);
      sc1.switch_mode(False);
      sc2.switch_mode(False);
   endrule

   Vector#(Delay, Reg#(Bit#(66))) sc1_wires <- replicateM(mkReg(0));
   Vector#(Delay, Reg#(Bit#(66))) sc2_wires <- replicateM(mkReg(0));
   for (Integer i=0; i<delay-1; i=i+1) begin
      rule connect;
            sc1_wires[i] <= fifo_sc1_to_sc2[i].first;
            sc2_wires[i] <= fifo_sc2_to_sc1[i].first;
            fifo_sc1_to_sc2[i].deq;
            fifo_sc2_to_sc1[i].deq;
            fifo_sc1_to_sc2[i+1].enq(sc1_wires[i]);
            fifo_sc2_to_sc1[i+1].enq(sc2_wires[i]);
      endrule
   end

   rule cyc;
      cycle <= cycle + 1;
   endrule

   rule start(toStart > 0);
      re.readServers[0].request.put(MemengineCmd{sglId:pointer, base:0, len:truncate(chunk), burstLen:truncate(burstLen*4)});
      toStart <= toStart - 1;
   endrule

   rule data;
      //let v <- toGet(re.dataPipes[0]).get;
      let v = 64'h79;
      write_encoder_data1.enq({2'b00, v[63:0]});
      write_encoder_data2.enq({2'b00, v[63:0]});

      if (cycle % 25000 == 0) begin
          Bit#(53) msg = {1'b0, zeroExtend(cycle)};
          sc1.dtpFromHost.enq(msg);
      end

      if(verbose) $display("mkDtpmTest.write_data v=%h", v[63:0]);
   endrule

   rule log_rcvd;
      let v <- toGet(sc2.dtpToHost).get;
      if(verbose) $display("%d: sc1 rcvd %d", cycle, v[52:0]);
   endrule

   rule out;
      let v <- toGet(sc1.dtpRxOut).get;
      if(verbose) $display("%d: sc1 out v=%h", cycle, v);
   endrule

   rule out2;
      let v <- toGet(sc2.dtpRxOut).get;
      if(verbose) $display("%d: sc2 out v=%h", cycle, v);
   endrule

   rule finish(toFinish > 0);
      let rv <- toGet(re.readServers[0].data).get;
      if (toFinish == 1) begin
         cf.deq;
         indication.dtpTestDone(0);
      end
      toFinish <= toFinish - 1;
   endrule

   interface dmaClient = vec(re.dmaClient);
   interface DtpmTestRequest request;
      method Action startDtpm(Bit#(32) rp, Bit#(32) nw, Bit#(32)bl, Bit#(32) ic) if(toStart == 0 && toFinish == 0);
         cf.enq(?);
         pointer  <= rp;
         numWords <= nw;
         burstLen <= bl;
         toStart  <= ic;
         toFinish <= ic;
      endmethod
   endinterface
endmodule

