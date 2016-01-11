// Copyright (c) 2016 Cornell University.

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

// NOTE:
// Implement a store-and-forward mechanism between ring-buffer and 
// main packet memory. Packets are buffered completely in ring buffer
// before it is sent to main memory and vice versa.

import Cntrs::*;
import FIFO::*;
import GetPut::*;
import Ethernet::*;
import SpecialFIFOs::*;
import SharedBuff::*;
import PacketBuffer::*;
import MemTypes::*;
import Malloc::*;
import MemServer::*;
import MemServerInternal::*;

typedef struct {
   Bit#(32) id;
   Bit#(PacketAddrLen) size;
} PacketInstance deriving(Bits, Eq);

interface StoreAndFwdFromRingToMem;
   interface PktReadClient readClient;
   interface Get#(Bit#(PacketAddrLen)) mallocReq;
   interface Put#(Bool) mallocDone;
   interface MemWriteClient#(`DataBusWidth) writeClient;
   interface Get#(PacketInstance) eventPktCommitted;
endinterface

module mkStoreAndFwdFromRingToMem(StoreAndFwdFromRingToMem);

   let verbose = True;

   // RingBuffer Read Client
   FIFO#(EtherData) readDataFifo <- mkFIFO;
   FIFO#(Bit#(EtherLen)) readLenFifo <- mkFIFO;
   FIFO#(EtherReq) readReqFifo <- mkFIFO;

   // Memory Client
   FIFO#(MemRequest) writeReqFifo <- mkSizedFIFO(4);
   FIFO#(MemData#(`DataBusWidth)) writeDataFifo <- mkSizedFIFO(32);
   FIFO#(Bit#(MemTagSize)) writeDoneFifo <- mkSizedFIFO(4);
   MemWriteClient#(`DataBusWidth) dmaWriteClient = (interface MemWriteClient;
   interface Get writeReq = toGet(writeReqFifo);
   interface Get writeData = toGet(writeDataFifo);
   interface Put writeDone = toPut(writeDoneFifo);
   endinterface);

   FIFO#(Bit#(PacketAddrLen)) mallocReqFifo <- mkFIFO;
   FIFO#(Bit#(EtherLen)) pktLenFifo <- mkFIFO;
   FIFO#(Bool) mallocDoneFifo <- mkFIFO;
   Reg#(Bool) readStarted <- mkReg(False);
   Reg#(Bool) mallocd <- mkReg(False);

   FIFO#(PacketInstance) eventPktReceivedFifo <- mkFIFO;
   FIFO#(PacketInstance) eventPktCommittedFifo <- mkFIFO;

   Reg#(Bit#(32)) cycle <- mkReg(0);
   rule every1 if (verbose);
      cycle <= cycle + 1;
   endrule

   rule packetReadStart if (!readStarted);
      let pktLen <- toGet(readLenFifo).get;
      if (verbose) $display("%d: ReadLen %d", cycle, pktLen);
      mallocReqFifo.enq(truncate(pktLen));
      pktLenFifo.enq(pktLen);
      readStarted <= True;
   endrule

   rule allocMemory;
      let pktLen <- toGet(pktLenFifo).get;
      let done <- toGet(mallocDoneFifo).get;
      if (done) begin
         mallocd <= True;
         readReqFifo.enq(EtherReq{len: truncate(pktLen)});
         writeReqFifo.enq(MemRequest {sglId: 0, offset: 0,
                                      burstLen: truncate(pktLen), tag:0
//`ifdef BYTE_ENABLES
                                      , firstbe: 'hffff, lastbe: 'hffff
//`endif
                                     });
         if (verbose) $display("%d: alloc done", cycle);
         eventPktReceivedFifo.enq(PacketInstance {id: 0, size: truncate(pktLen)});
      end
   endrule

   rule packetReadInProgress if (readStarted && mallocd);
      let v <- toGet(readDataFifo).get;
      if (verbose) $display(fshow(" packet ") + fshow(v));
      if (v.eop) begin
         readStarted <= False;
         mallocd <= False;
         $display("%d: packet finished", cycle);
      end
      $display("StoreAndForward::writeData: data:%h, tag:%h, last:%h", v.data, 0, v.eop);
      writeDataFifo.enq(MemData {data: v.data, tag: 0, last: v.eop});
   endrule

   rule packetReadDone;
      let v <- toGet(writeDoneFifo).get;
      let recvd <- toGet(eventPktReceivedFifo).get;
      $display("%d: packet written to memory %h", cycle, v);
      eventPktCommittedFifo.enq(recvd);
   endrule

   interface PktReadClient readClient;
      interface readData = toPut(readDataFifo);
      interface readLen = toPut(readLenFifo);
      interface readReq = toGet(readReqFifo);
   endinterface

   interface Get mallocReq = toGet(mallocReqFifo);
   interface Put mallocDone = toPut(mallocDoneFifo);
   interface writeClient = dmaWriteClient;
   interface Get eventPktCommitted = toGet(eventPktCommittedFifo);
endmodule

interface StoreAndFwdFromMemToRing;
   interface PktWriteClient writeClient;
   interface MemReadClient#(`DataBusWidth) readClient;
   interface Put#(PacketInstance) eventPktSend;
endinterface

module mkStoreAndFwdFromMemToRing(StoreAndFwdFromMemToRing);

   let verbose = True;

   // Ring Buffer Write Client
   FIFO#(EtherData) writeDataFifo <- mkFIFO;

   // read client interface
   FIFO#(MemRequest) readReqFifo <-mkSizedFIFO(4);
   FIFO#(MemData#(`DataBusWidth)) readDataFifo <- mkSizedFIFO(32);
   MemReadClient#(`DataBusWidth) dmaReadClient = (interface MemReadClient;
   interface Get readReq = toGet(readReqFifo);
   interface Put readData = toPut(readDataFifo);
   endinterface);

   FIFO#(PacketInstance) eventPktSendFifo <- mkFIFO;

   Count#(Bit#(12)) readDataCnt <- mkCount(0);
   Reg#(Bit#(12)) readDataSize <- mkReg(0);

   Reg#(Bit#(32)) cycle <- mkReg(0);
   rule every1 if (verbose);
      cycle <= cycle + 1;
   endrule

   rule packetReadStart;
      let v <- toGet(eventPktSendFifo).get;
      $display("%d: send a new packet with size %h", cycle, v.size);
      readReqFifo.enq(MemRequest{sglId: v.id, offset: 0,
                                  burstLen: truncate(v.size), tag: 0
//`ifdef BYTE_ENABLES
                                  , firstbe: 'hffff, lastbe: 'hffff
//`endif
                                });
      readDataCnt <= v.size >> 4;
      readDataSize <= v.size >> 4;
   endrule

   rule packetReadInProgress;
      let d <- toGet(readDataFifo).get;
      Bool sop = (readDataCnt == readDataSize) ? True : False;
      Bool eop = (readDataCnt == 1) ? True : False;
      readDataCnt.decr(1);
      if (verbose) $display("%d: readdata %h %h %h %h", cycle, readDataCnt, d.data, sop, eop);
      writeDataFifo.enq(EtherData{data: d.data, mask: 'hff, sop: sop, eop: eop});
   endrule

   interface PktWriteClient writeClient;
      interface writeData = toGet(writeDataFifo);
   endinterface
   interface readClient = dmaReadClient;
   interface Put eventPktSend = toPut(eventPktSendFifo);
endmodule

