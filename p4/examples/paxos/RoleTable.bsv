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

import ClientServer::*;
import DbgTypes::*;
import Ethernet::*;
import FIFO::*;
import GetPut::*;
import PaxosTypes::*;

typedef enum {
   Acceptor = 1,
   Coordinator = 2
} Role deriving (Bits);

interface RoleTable;
   interface Client#(MetadataRequest, MetadataResponse) next0;
   interface Client#(MetadataRequest, MetadataResponse) next1;
   interface Client#(RoundRegRequest, RoundRegResponse) regAccess;
endinterface

module mkRoleTable#(Client#(MetadataRequest, MetadataResponse) md)(RoleTable);
   Reg#(Bit#(64)) lookupCnt <- mkReg(0);
   Reg#(Role) role <- mkReg(Acceptor);

   FIFO#(MetadataRequest) outReqFifo <- mkFIFO;
   FIFO#(MetadataResponse) inRespFifo <- mkFIFO;
   FIFO#(PacketInstance) currPacketFifo <- mkFIFO;

   rule tableLookupRequest;
      let v <- md.request.get;
      $display("Role: table lookup request");
      case (v) matches
         tagged RoleLookupRequest {pkt: .pkt}: begin
            case (role) matches
               Acceptor: begin
                  $display("Role: Acceptor %h", pkt.id);
                  MetadataRequest nextReq = tagged RoundTblRequest {pkt: pkt};
                  outReqFifo.enq(nextReq);
               end
               Coordinator: begin
                  $display("Role: Coordinator %h", pkt.id);
                  MetadataRequest nextReq = tagged SequenceTblRequest {pkt: pkt};
                  outReqFifo.enq(nextReq);
               end
            endcase
            lookupCnt <= lookupCnt + 1;
         end
      endcase
   endrule

   interface next0 = (interface Client#(MetadataRequest, MetadataResponse);
      interface request = toGet(outReqFifo);
      interface response = toPut(inRespFifo);
   endinterface);
endmodule