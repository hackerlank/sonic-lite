import Vector::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import BRAM::*;
import GetPut::*;
import DefaultValue::*;
import Clocks::*;

import SchedulerTypes::*;
import RingBufferTypes::*;
import RingBuffer::*;
`ifdef SIM
import MachineToPortMappingSim::*;
`else
import MachineToPortMapping::*;
`endif
import GlobalClock::*;
import Addresses::*;
import MaxMinFairness::*;
import MinPriorityQueue::*;

typedef struct {
	ReadResType data;
	PortIndex tx_port;
} DataToPutInTx deriving(Bits, Eq);

instance DefaultValue#(DataToPutInTx);
	defaultValue = DataToPutInTx {
					data : defaultValue,
					tx_port : fromInteger(valueof(NUM_OF_ALTERA_PORTS))
				};
endinstance

typedef struct {
    ServerIndex src;
    ServerIndex dst;
    Bit#(16) flow_id;
    Bit#(16) seq_num;
    Bit#(1) op;
} FlowUpdateT deriving(Bits, Eq);

interface Scheduler#(type readReqType, type readResType,
                     type writeReqType, type writeResType);

    /* MAC interface */
	interface Vector#(NUM_OF_ALTERA_PORTS, Put#(readReqType)) mac_read_request_port;
	interface Vector#(NUM_OF_ALTERA_PORTS, Get#(readResType)) mac_read_response_port;
	interface Vector#(NUM_OF_ALTERA_PORTS, Put#(writeReqType)) mac_write_request_port;
	interface Vector#(NUM_OF_ALTERA_PORTS, Get#(writeResType)) mac_write_response_port;

    /* DMA simulator interface */
    interface Put#(readReqType) dma_read_request;
    interface Put#(writeReqType) dma_write_request;
    interface Get#(readResType) dma_read_response;
    interface Get#(writeResType) dma_write_response;

	interface Get#(Bit#(64)) time_slots_response;
	interface Get#(Bit#(64)) host_pkt_response;
	interface Get#(Bit#(64)) non_host_pkt_response;
	interface Get#(Bit#(64)) received_pkt_response;
	interface Get#(Bit#(64)) rxWrite_pkt_response;
	interface Vector#(NUM_OF_SERVERS, Get#(Vector#(RING_BUFFER_SIZE, Bit#(64))))
					                                               fwd_queue_len;
//	interface Get#(RingBufferDataT) debug_consuming_pkt;

	method Action start(ServerIndex serverIdx);
	method Action stop();
	method Action insertToSchedTable(ServerIndex index, IP ip_addr, MAC mac_addr);
    method Action timeSlotsCount();
	method Action hostPktCount();
	method Action nonHostPktCount();
	method Action receivedPktCount();
	method Action rxWritePktCount();
	method Action fwdQueueLen();
endinterface

(* synthesize *)
module mkScheduler#(Clock pcieClock, Reset pcieReset,
                    Clock txClock, Reset txReset,
                    Vector#(NUM_OF_ALTERA_PORTS, Clock) rxClock,
					Vector#(NUM_OF_ALTERA_PORTS, Reset) rxReset)
				(Scheduler#(ReadReqType, ReadResType, WriteReqType, WriteResType));

    Reg#(Bool) verbose <- mkReg(False);

    GlobalClock clk <- mkGlobalClock;

	Reg#(ServerIndex) host_index <- mkReg(0);

    Clock defaultClock <- exposeCurrentClock();
    Reset defaultReset <- exposeCurrentReset();

    Vector#(NUM_OF_ALTERA_PORTS, FIFO#(ReadReqType)) mac_read_request_fifo
            <- replicateM(mkSizedFIFO(valueof(DEFAULT_FIFO_LEN)));
    Vector#(NUM_OF_ALTERA_PORTS, FIFO#(ReadResType)) mac_read_response_fifo
            <- replicateM(mkSizedFIFO(valueof(DEFAULT_FIFO_LEN)));
    Vector#(NUM_OF_ALTERA_PORTS, SyncFIFOIfc#(WriteReqType)) mac_write_request_fifo;
    Vector#(NUM_OF_ALTERA_PORTS, SyncFIFOIfc#(WriteResType)) mac_write_response_fifo;

	for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
	begin
		mac_write_request_fifo[i] <- mkSyncFIFO(valueof(DEFAULT_FIFO_LEN),
	                                      rxClock[i], rxReset[i], defaultClock);
		mac_write_response_fifo[i] <- mkSyncFIFO(valueof(DEFAULT_FIFO_LEN),
	                                    defaultClock, defaultReset, rxClock[i]);
	end

    FIFO#(ReadReqType) dma_read_request_fifo
	                 <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));
    FIFO#(ReadResType) dma_read_response_fifo
	                 <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));
    FIFO#(WriteReqType) dma_write_request_fifo
	                 <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));
    FIFO#(WriteResType) dma_write_response_fifo
	                 <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));

    Reg#(State) curr_state <- mkReg(CONFIG);

/*-------------------------------------------------------------------------------*/
                        // Ring buffers and Schedule table
/*-------------------------------------------------------------------------------*/
    Vector#(NUM_OF_ALTERA_PORTS,
            RingBuffer#(ReadReqType, ReadResType, WriteReqType, WriteResType))
    rx_ring_buffer <- replicateM(mkRingBuffer(valueof(RING_BUFFER_SIZE)));

    Vector#(NUM_OF_ALTERA_PORTS,
            RingBuffer#(ReadReqType, ReadResType, WriteReqType, WriteResType))
    tx_ring_buffer <- replicateM(mkRingBuffer(valueof(RING_BUFFER_SIZE)));

    Vector#(NUM_OF_SERVERS,
            RingBuffer#(ReadReqType, ReadResType, WriteReqType, WriteResType))
    ring_buffer <- replicateM(mkRingBuffer(valueof(RING_BUFFER_SIZE)));

    RingBuffer#(ReadReqType, ReadResType, WriteReqType, WriteResType)
        src_rx_ring_buffer <- mkRingBuffer(valueof(RING_BUFFER_SIZE));

	Vector#(NUM_OF_SERVERS, Reg#(TableData)) sched_table
	                                    <- replicateM(mkReg(defaultValue));

    Vector#(NUM_OF_SERVERS, Reg#(ServerIndex)) schedule_list <- replicateM(mkReg(0));

    MaxMinFairness mmf <- mkMaxMinFairness;

    /* Flags */
    Reg#(Bit#(1)) configure <- mkReg(0);
    Reg#(Bit#(1)) start_scheduling_flag <- mkReg(0);
    Reg#(Bit#(1)) start_polling_rx_buffer <- mkReg(0);
	Reg#(Bit#(1)) start_tx_scheduling <- mkReg(0);

    MinPriorityQueue#(Bit#(16), Bit#(16)) priority_queue <- mkMinPriorityQueue;
/*-------------------------------------------------------------------------------*/
                                 // Statistics
/*-------------------------------------------------------------------------------*/
	SyncFIFOIfc#(Bit#(64)) time_slots_fifo
	        <- mkSyncFIFO(1, defaultClock, defaultReset, pcieClock);
	SyncFIFOIfc#(Bit#(64)) host_pkt_fifo
	        <- mkSyncFIFO(1, defaultClock, defaultReset, pcieClock);
	SyncFIFOIfc#(Bit#(64)) non_host_pkt_fifo
	        <- mkSyncFIFO(1, defaultClock, defaultReset, pcieClock);
	SyncFIFOIfc#(Bit#(64)) received_pkt_fifo
	        <- mkSyncFIFO(1, defaultClock, defaultReset, pcieClock);
	SyncFIFOIfc#(Bit#(64)) rxWrite_pkt_fifo
	        <- mkSyncFIFO(1, defaultClock, defaultReset, pcieClock);
	Reg#(Bit#(64)) num_of_time_slots_used_reg <- mkReg(0);
	Reg#(Bit#(64)) host_pkt_transmitted_reg <- mkReg(0);
	Reg#(Bit#(64)) non_host_pkt_transmitted_reg <- mkReg(0);
	Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(64))) num_of_pkt_received_reg
	                                     <- replicateM(mkReg(0));
	Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(64))) num_of_rxWrite_pkt_reg
	                                     <- replicateM(mkReg(0));

	Vector#(NUM_OF_SERVERS, SyncFIFOIfc#(Vector#(RING_BUFFER_SIZE, Bit#(64))))
		    fwd_queue_len_fifo <- replicateM(mkSyncFIFO(valueof(NUM_OF_SERVERS),
								        defaultClock, defaultReset, pcieClock));

	Vector#(NUM_OF_SERVERS, Vector#(RING_BUFFER_SIZE, Reg#(Bit#(64))))
						fwd_queue_len_reg <- replicateM(replicateM(mkReg(0)));

	Reg#(ServerIndex) measure <- mkReg(fromInteger(valueof(NUM_OF_SERVERS)));
    Vector#(NUM_OF_SERVERS, Reg#(Bit#(5))) len_index
                <- replicateM(mkReg(fromInteger(valueof(RING_BUFFER_SIZE))));

	for (Integer i = 0; i < valueof(NUM_OF_SERVERS); i = i + 1)
	begin
		rule monitor_ring_buffers (curr_state == RUN && measure == fromInteger(i));
			let len <- ring_buffer[i].elements;
            len_index[i] <= truncate(len);
            measure <= fromInteger(valueof(NUM_OF_SERVERS));
		endrule

        for (Integer j = 0; j < valueof(RING_BUFFER_SIZE); j = j + 1)
        begin
            rule update_counter (curr_state == RUN
                                 && len_index[i] == fromInteger(j));
                fwd_queue_len_reg[i][j] <= fwd_queue_len_reg[i][j] + 1;
                len_index[i] <= fromInteger(valueof(RING_BUFFER_SIZE));
            endrule
        end
	end

	Vector#(NUM_OF_SERVERS, Reg#(Bit#(1))) enq_queue_length <- replicateM(mkReg(0));
	for (Integer i = 0; i < valueof(NUM_OF_SERVERS); i = i + 1)
	begin
		rule enq_queue_length_rule (enq_queue_length[i] == 1);
			enq_queue_length[i] <= 0;
			Vector#(RING_BUFFER_SIZE, Bit#(64)) temp = replicate(0);
			for (Integer j = 0; j < valueof(RING_BUFFER_SIZE); j = j + 1)
				temp[j] = fwd_queue_len_reg[i][j];
			fwd_queue_len_fifo[i].enq(temp);
		endrule
	end

//	SyncFIFOIfc#(RingBufferDataT) debug_consuming_pkt_fifo
//	        <- mkSyncFIFO(16, defaultClock, defaultReset, pcieClock);

/*-------------------------------------------------------------------------------*/

    // Here the assumption is that since it is our own
    // network, so we assign the IP addresses to the
    // machines in such a way that the mapping IP -> index
    // is trivial. For eg. currently I am assuming that the
    // IP addresses have been assigned such as the mapping
    // is index = least significant byte of IP address - 1.
    // So the IP addrs may be like 192.168.0.1, 192.168.0.2,
    // 192.168.0.3 etc. Note that this is just to make processing
    // faster and saving memory resources. If this approach is not
    // viable in a particular setting, then we can rely back on
    // storing the mapping in a table in BRAM memory, and traversing
    // the table every time we need to know the index of a ring
    // buffer.

    function ServerIndex ipToIndexMapping (IP ip_addr);
		ServerIndex index = 0;
		Bit#(24) msb = ip_addr[31:8];

        if (ip_addr == ip_address(host_index))
            index = 0;

		else if (msb == 'hc0a800 && ip_addr != 'hc0a80000)
		begin
			index = truncate(ip_addr[7:0]) - 1;
			if (index < truncate((ip_address(host_index))[7:0]))
				index = index + 1;
		end

        else
			index = fromInteger(valueof(NUM_OF_SERVERS));

        return index;
    endfunction

    // 0th entry in the schedule table will always contain the info of the
    // host server. Entries 1 to NUM_OF_SERVERS-1 will contain info of the
    // remaining servers. As there will be a total of NUM_OF_SERVERS-1 time
    // slots, so the size of schedule_list is NUM_OF_SERVERS-1.
    //
    // schedule_list[i] = j means in time slot i, send pkt to server at index
    // j in the schedule table.

    rule configure_scheduling (curr_state == RUN && configure == 1);
        configure <= 0;
        for (Integer i = 0; i < valueof(NUM_OF_SERVERS)-1; i = i + 1)
        begin
            schedule_list[i] <= fromInteger(i) + 1;
            if (verbose)
            $display("[SCHED (%d)] schedule_list[%d] = %d", host_index, i, i+1);
        end
        start_scheduling_flag <= 1;
    endrule

    rule start_scheduling (curr_state == RUN && start_scheduling_flag == 1);
        start_scheduling_flag <= 0;
        start_polling_rx_buffer <= 1;
		start_tx_scheduling <= 1;
    endrule

/*-------------------------------------------------------------------------------*/
                                  // Rx Path
/*-------------------------------------------------------------------------------*/
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(IP)) recvd_pkt_src_ip <- replicateM(mkReg(0));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(IP)) recvd_pkt_dst_ip <- replicateM(mkReg(0));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(1)))
                                        recvd_pkt_ctrl_bits <- replicateM(mkReg(0));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(16)))
                                        recvd_pkt_flow_id <- replicateM(mkReg(0));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(16)))
                                        recvd_pkt_seq_num <- replicateM(mkReg(0));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(1)))
                              check_flow_add_remove_rx_flag <- replicateM(mkReg(0));

    Vector#(NUM_OF_ALTERA_PORTS, FIFO#(FlowUpdateT))
          flow_update_fifo_rx <- replicateM(mkSizedFIFO(valueof(DEFAULT_FIFO_LEN)));

	// should be atleast as large as buffer_depth + max num of data blocks
    Vector#(NUM_OF_ALTERA_PORTS, FIFOF#(RingBufferDataT)) buffer_fifo
	                    <- replicateM(mkSizedFIFOF(valueof(DEFAULT_FIFO_LEN)));
    Vector#(NUM_OF_ALTERA_PORTS, FIFOF#(ServerIndex)) ring_buffer_index_fifo
                 <- replicateM(mkSizedFIFOF((valueof(NUM_OF_ALTERA_PORTS)+1)));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(1)))
                 ready_to_deq_from_index_buffer <- replicateM(mkReg(1));
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(1)))
                  ready_to_deq_from_ring_buffer <- replicateM(mkReg(0));

    /* Stores the number of data blocks to buffer */
    Vector#(NUM_OF_ALTERA_PORTS, Reg#(int)) buffer_depth <- replicateM(mkReg(3));

    //
    // Have to buffer first 3 data blocks to get to dst IP addr
    //
    // Assumption here is that the MAC Frame structure is as shown
    // ------------------------------------------------------
    // | dst MAC | src MAC | ether type | IP header | Payload |
    // ------------------------------------------------------
    // So, no VLAN tags etc.
    //

    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(384))) buffered_data <- replicateM(mkReg(0));

    Vector#(NUM_OF_ALTERA_PORTS, Reg#(Bit#(1))) stop_polling <- replicateM(mkReg(0));

    Vector#(NUM_OF_ALTERA_PORTS, Reg#(ServerIndex)) curr_ring_buffer_index
                        <- replicateM(mkReg(fromInteger(valueof(NUM_OF_SERVERS))));

    Vector#(NUM_OF_SERVERS, FIFOF#(PortIndex))
    token_queue <- replicateM(mkSizedFIFOF(valueof(NUM_OF_SERVERS)));

    for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
    begin
        rule check_flow_add_remove_rx (check_flow_add_remove_rx_flag[i] == 1);
            check_flow_add_remove_rx_flag[i] <= 0;

            /* Check if the flow already exits */
            ServerIndex src = host_id(recvd_pkt_src_ip[i]);
            ServerIndex dst = host_id(recvd_pkt_dst_ip[i]);

            if (src < fromInteger(valueof(NUM_OF_SERVERS))
                && dst < fromInteger(valueof(NUM_OF_SERVERS)))
            begin
                if (recvd_pkt_ctrl_bits[i] == 'b1)
                begin
                    let d = FlowUpdateT {
                                src : src,
                                dst : dst,
                                flow_id : recvd_pkt_flow_id[i],
                                seq_num : recvd_pkt_seq_num[i],
                                op  : 0
                            };
                    flow_update_fifo_rx[i].enq(d);
                end

                else
                begin
                    let d = FlowUpdateT {
                                src : src,
                                dst : dst,
                                flow_id : recvd_pkt_flow_id[i],
                                seq_num : recvd_pkt_seq_num[i],
                                op  : 1
                            };
                    flow_update_fifo_rx[i].enq(d);
                end
            end
        endrule

        rule start_polling_rx (curr_state == RUN && start_polling_rx_buffer == 1
                               && stop_polling[i] == 0);
            let ring_buf_empty <- rx_ring_buffer[i].empty;

            if (!ring_buf_empty)
            begin
				num_of_pkt_received_reg[i] <= num_of_pkt_received_reg[i] + 1;
                rx_ring_buffer[i].read_request.put(makeReadReq(READ));
				stop_polling[i] <= 1;
            end
        endrule


// Buf Reg 383    336 337   289              175   144 143    112         0
//          ---------------------------------------------------------------
//         | dst MAC | src MAC | .....|..... | src IP | dst | IP | Payload |
//          ---------------------------------------------------------------
// Memory  0                       127  128              255  256        383

        rule buffer_and_parse_incoming_data (curr_state == RUN);
            let d <- rx_ring_buffer[i].read_response.get;

            if (d.data.sop == 1 && d.data.eop == 0)
            begin
                Bit#(384) pload = zeroExtend(d.data.payload);
				buffered_data[i] <= buffered_data[i] |
				(pload << (fromInteger(valueof(BUS_WIDTH)) * (buffer_depth[i]-1)));
                buffer_depth[i] <= buffer_depth[i] - 1;
                buffer_fifo[i].enq(d.data);
            end

            else
            begin
                if (buffer_depth[i] > 0)
                begin
                    if (d.data.sop == 0 && d.data.eop == 1)
                    begin
                        /* reset state */
                        buffer_depth[i] <= 3;  //no of data blocks to buffer
                        buffered_data[i] <= 0;
						ring_buffer_index_fifo[i].enq(0);
                    end
					else
					begin
						buffer_depth[i] <= buffer_depth[i] - 1;
						Bit#(384) pload = zeroExtend(d.data.payload);
						buffered_data[i] <= buffered_data[i] | (pload
									<< (fromInteger(valueof(BUS_WIDTH))
											   * (buffer_depth[i]-1)));
					end
                end

                else if (buffer_depth[i] == 0) /* already buffered 3 data blocks */
                begin
                    if (d.data.sop == 0 && d.data.eop == 1)
                    begin
                        /* reset state */
                        buffer_depth[i] <= 3;  //num of data blocks to buffer
                        buffered_data[i] <= 0;
                    end
                    else
                        buffer_depth[i] <= buffer_depth[i] - 1;

                    /* Find the index of the ring buffer to insert to. */
                    IP dst_ip = (buffered_data[i])[143:112];
                    IP src_ip = (buffered_data[i])[175:144];
                    Bit#(1) ctrl_bits = (buffered_data[i])[258];

                    /* Check if a flow is to be added or removed */
                    recvd_pkt_src_ip[i] <= src_ip;
                    recvd_pkt_dst_ip[i] <= dst_ip;
                    recvd_pkt_ctrl_bits[i] <= ctrl_bits;
                    recvd_pkt_flow_id[i] <= (buffered_data[i])[255:240];
                    recvd_pkt_seq_num[i] <= (buffered_data[i])[239:224];
                    check_flow_add_remove_rx_flag[i] <= 1;

                    if (dst_ip == ip_address(host_index))
                        ring_buffer_index_fifo[i].enq(0);
                    else
                    begin
                        ServerIndex index = ipToIndexMapping(dst_ip);
						if (index >= fromInteger(valueof(NUM_OF_SERVERS)))
                        begin
                            ring_buffer_index_fifo[i].enq(0);
                        end
                        else
                            ring_buffer_index_fifo[i].enq(index);

                        if (verbose)
                            $display("[SCHED (%d)] Adding idx = %d to idx fifo %d",
                                     host_index, index, i);
                    end
                end

                else if (d.data.sop == 0 && d.data.eop == 1)
                begin
                    /* reset state */
                    buffer_depth[i] <= 3;  //num of data blocks to buffer
                    buffered_data[i] <= 0;
                end

                buffer_fifo[i].enq(d.data);
            end
        endrule

        rule extract_ring_buffer_index_to_add_to
                    (curr_state == RUN && ready_to_deq_from_index_buffer[i] == 1);
            let index <- toGet(ring_buffer_index_fifo[i]).get;
            curr_ring_buffer_index[i] <= index;
            ready_to_deq_from_index_buffer[i] <= 0;
            ready_to_deq_from_ring_buffer[i] <= 1;
        endrule

        for (Integer j = 0; j < valueof(NUM_OF_SERVERS); j = j + 1)
        begin
            rule enq_to_token_queue (curr_state == RUN
                                  && curr_ring_buffer_index[i] == fromInteger(j));
                token_queue[j].enq(fromInteger(i));
                if (verbose)
                $display("[SCHED (%d)] token_queue[%d].enq(%d)", host_index, j, i);
                curr_ring_buffer_index[i] <= fromInteger(valueof(NUM_OF_SERVERS));
            endrule
        end
    end

    Vector#(NUM_OF_SERVERS, Reg#(PortIndex))
         port_idx <- replicateM(mkReg(fromInteger(valueof(NUM_OF_ALTERA_PORTS))));

	Vector#(NUM_OF_SERVERS, Reg#(Bit#(1))) wait_for_completion
	                                            <- replicateM(mkReg(0));

    Vector#(NUM_OF_ALTERA_PORTS, Vector#(NUM_OF_SERVERS, Reg#(Bit#(1))))
            dont_add_to_buffer <- replicateM(replicateM(mkReg(0)));

    for (Integer j = 0; j < valueof(NUM_OF_SERVERS); j = j + 1)
    begin
        rule deq_from_token_queue (curr_state == RUN
			                       && wait_for_completion[j] == 0);
            let port_index <- toGet(token_queue[j]).get;
            port_idx[j] <= port_index;
            if (verbose)
                $display("[SCHED (%d)] port_idx[%d] = %d",host_index,j,port_index);
			wait_for_completion[j] <= 1;
        endrule

        for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
        begin
            rule add_to_correct_ring_buffer (curr_state == RUN
                                        && port_idx[j] == fromInteger(i)
                                        && ready_to_deq_from_ring_buffer[i] == 1);
                let d <- toGet(buffer_fifo[i]).get;
				if (d.sop == 1 && d.eop == 0)
                begin
					stop_polling[i] <= 0;
                    if (d.payload[2] == 1)
                        dont_add_to_buffer[i][j] <= 1;
                end

                else if (d.sop == 0 && d.eop == 1)
                begin
                    ready_to_deq_from_index_buffer[i] <= 1;
                    ready_to_deq_from_ring_buffer[i] <= 0;
					wait_for_completion[j] <= 0;
                    port_idx[j] <= fromInteger(valueof(NUM_OF_ALTERA_PORTS));
                    dont_add_to_buffer[i][j] <= 0;
                end

                if (dont_add_to_buffer[i][j] == 0)
                begin
                    if (j != 0)
                        ring_buffer[j].write_request.put
                                        (makeWriteReq(d.sop, d.eop, d.payload));
                    else
                        src_rx_ring_buffer.write_request.put
                                        (makeWriteReq(d.sop, d.eop, d.payload));
                    if (verbose)
                        $display("[SCHED (%d)] CLK = %d buffer index to put data = %d data = %d %d %x", host_index, clk.currTime(), j, d.sop, d.eop, d.payload);
                end
            endrule
        end
    end

/*-------------------------------------------------------------------------------*/
                                  // Tx Path
/*-------------------------------------------------------------------------------*/
    Reg#(ServerIndex) curr_slot <- mkReg(0);
    Reg#(MAC) dst_mac_addr <- mkReg(0);
    Reg#(Bit#(1)) flow_add_blast_phase <- mkReg(0);
    Reg#(ServerIndex) flow_add_blast_phase_count <- mkReg(0);
    Reg#(Bit#(1)) flow_rem_blast_phase <- mkReg(0);
    Reg#(ServerIndex) flow_rem_blast_phase_count <- mkReg(0);

    Reg#(Bit#(1)) check_flow_add_remove_tx_flag <- mkReg(0);
    FIFO#(FlowUpdateT) flow_update_fifo_tx <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));

    Reg#(Bit#(384)) buf_data <- mkReg(0);

    FIFO#(Bit#(1)) send_flow_rem_pkt_fifo <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));

    FIFO#(Bit#(1)) check_to_end_flow_add_rem_blast_fifo <- mkFIFO;

    rule check_flow_add_remove_tx (check_flow_add_remove_tx_flag == 1);
        check_flow_add_remove_tx_flag <= 0;

        IP dst_ip = buf_data[143:112];
        IP src_ip = buf_data[175:144];
        Bit#(1) ctrl_bits = buf_data[258];
        Bit#(16) flow_id = buf_data[255:240];
        Bit#(16) seq_num = buf_data[239:224];

        ServerIndex src = host_id(src_ip);
        ServerIndex dst = host_id(dst_ip);

        if (src == host_index
            && dst < fromInteger(valueof(NUM_OF_SERVERS)))
        begin
            if (ctrl_bits == 'b1 && mmf.flowExists(src, dst))
            begin
                let d = FlowUpdateT {
                            src : src,
                            dst : dst,
                            flow_id : flow_id,
                            seq_num : seq_num,
                            op  : 0
                        };
                flow_update_fifo_tx.enq(d);
                flow_rem_blast_phase <= 1;
                flow_rem_blast_phase_count <= 0;
            end

            else if (!mmf.flowExists(src, dst))
            begin
                let d = FlowUpdateT {
                            src : src,
                            dst : dst,
                            flow_id : flow_id,
                            seq_num : seq_num,
                            op  : 1
                        };
                flow_update_fifo_tx.enq(d);
                flow_add_blast_phase <= 1;
                flow_add_blast_phase_count <= 0;
            end
        end
    endrule

    rule get_dst_addr (curr_state == RUN && start_tx_scheduling == 1);
		Bit#(64) curr_time = clk.currTime();

		Bit#(3) clock_lsb_three_bits = curr_time[2:0];
		if (clock_lsb_three_bits == 0)
		begin
			ServerIndex slot = 0;
            if (valueof(NUM_OF_SERVERS) == 1)
                slot = 0;
            else
            begin
			    slot = curr_slot;
                if (curr_slot == (fromInteger(valueof(NUM_OF_SERVERS))-2))
                    curr_slot <= 0;
                else
                    curr_slot <= curr_slot + 1;
            end

			if (verbose)
            $display("[SCHED (%d)] CLK = %d  schedule_list[%d] = %d", host_index,
                            curr_time, slot, schedule_list[slot]);

            num_of_time_slots_used_reg <= num_of_time_slots_used_reg + 1;

			/* Get the dst mac and ip addr */
			ServerIndex table_index = schedule_list[slot];
			dst_mac_addr <= sched_table[table_index].server_mac;
			IP dst_ip_addr = sched_table[table_index].server_ip;

			if (verbose)
				$display("[SCHED (%d)] CLK = %d MAC = %x IP = %x", host_index,
				clk.currTime(), sched_table[table_index].server_mac,
			    dst_ip_addr);

			/* Get the index of the ring buffer to extract from */
			ServerIndex index = ipToIndexMapping(dst_ip_addr);

			measure <= index;

			if (verbose)
			$display("[SCHED (%d)] CLK = %d buffer index to extract from = %d %d",
				host_index, clk.currTime(), index, ring_buffer[index].elements);

			Bool is_empty <- ring_buffer[index].empty;

			//
			// Only if the forwarding ring buffer is empty, extract packet from
			// the host tx buffer.
			//
            if (!is_empty && flow_add_blast_phase == 0 && flow_rem_blast_phase == 0)
				ring_buffer[index].read_request.put(makeReadReq(READ));

			else
			begin
				if (verbose)
				begin
				$display("[SCHED (%d)] CLK = %d Empty ring; extract from host tx",
													  host_index, clk.currTime());
				$display("[SCHED (%d)] Host tx buffer size = %d", host_index,
													  ring_buffer[0].elements);
				end

                if (flow_add_blast_phase == 1)
                begin
                    ring_buffer[0].read_request.put(makeReadReq(READ));
                    flow_add_blast_phase_count <= flow_add_blast_phase_count + 1;
                    if (flow_add_blast_phase_count == fromInteger(valueof(NUM_OF_SERVERS))-2)
                    begin
                        flow_add_blast_phase <= 0;
                    end
                end

                else if (flow_rem_blast_phase == 1)
                begin
                    flow_rem_blast_phase_count <= flow_rem_blast_phase_count + 1;
                    if (flow_rem_blast_phase_count == fromInteger(valueof(NUM_OF_SERVERS))-2)
                    begin
                        ring_buffer[0].read_request.put(makeReadReq(REMOVE));
                        flow_rem_blast_phase <= 0;
                    end
                    else
                        ring_buffer[0].read_request.put(makeReadReq(READ));
                end

                else
                    ring_buffer[0].read_request.put(makeReadReq(READ));
			end
		end
    endrule

    Vector#(NUM_OF_SERVERS, FIFO#(DataToPutInTx)) data_to_put
	            <- replicateM(mkSizedFIFO(valueof(DEFAULT_FIFO_LEN)));
	Vector#(NUM_OF_SERVERS, Reg#(PortIndex)) tx_port_index <- replicateM(mkReg(0));

    Vector#(NUM_OF_SERVERS, FIFO#(ReadResType)) data_fifo
	                                           <- replicateM(mkBypassFIFO);
	Vector#(NUM_OF_SERVERS, Wire#(PortIndex)) correct_tx_index
	             <- replicateM(mkDWire(fromInteger(valueof(NUM_OF_ALTERA_PORTS))));

    Reg#(Bit#(2)) c <- mkReg(0);

    for (Integer i = 0; i < valueof(NUM_OF_SERVERS); i = i + 1)
    begin
        rule modify_mac_headers_and_put_to_tx (curr_state == RUN);
            let d <- ring_buffer[i].read_response.get;

            // Check for start of flow / end of flow
            if (i == 0 && flow_add_blast_phase == 0 && flow_rem_blast_phase == 0)
            begin
                if (d.data.sop == 1 && d.data.eop == 0)
                begin
                    c <= 1;
                    Bit#(384) temp = zeroExtend(d.data.payload);
                    buf_data <= buf_data
                                   | (temp << (2*fromInteger(valueof(BUS_WIDTH))));
                end
                else if (c == 1) //2nd data block
                begin
                    c <= c + 1;
                    Bit#(384) temp = zeroExtend(d.data.payload);
                    buf_data <= buf_data
                                   | (temp << fromInteger(valueof(BUS_WIDTH)));
                end
                else if (c == 2) //3rd data block
                begin
                    c <= c + 1;
                    buf_data <= buf_data | (zeroExtend(d.data.payload));
                    check_flow_add_remove_tx_flag <= 1;
                end
            end

            if (d.data.sop == 1 && d.data.eop == 0)
            begin
                /* Update MAC header */
                Bit#(96) new_addr = {dst_mac_addr, mac_address(host_index)};
                Bit#(96) zero = 0;
                Bit#(BUS_WIDTH) temp = {zero, '1};
				Bit#(BUS_WIDTH) new_addr_temp = {new_addr, '0};
                d.data.payload = (d.data.payload & temp) | new_addr_temp;
                PortIndex index = machineToPortMapping(host_index, dst_mac_addr);
				tx_port_index[i] <= index;
                if (i == 0)
                    host_pkt_transmitted_reg <= host_pkt_transmitted_reg + 1;
                else
                    non_host_pkt_transmitted_reg <=
					                        non_host_pkt_transmitted_reg + 1;

                d.data.payload[3] = 0;

				DataToPutInTx x = DataToPutInTx {
									data : d,
									tx_port : index
								};
				data_to_put[i].enq(x);
            end

			else
			begin
				DataToPutInTx x = DataToPutInTx {
									data : d,
									tx_port : tx_port_index[i]
								};
				data_to_put[i].enq(x);
			end

            if (verbose)
                $display("[SCHED (%d)] CLK = %d", host_index, clk.currTime());
        endrule

		rule set_correct_tx_index (curr_state == RUN);
			let res <- toGet(data_to_put[i]).get;
			ReadResType d = res.data;
			PortIndex idx = res.tx_port;
			data_fifo[i].enq(d);
			correct_tx_index[i] <= idx;
		if (verbose)
		$display("[SCHED (%d)] CLK = %d data written to tx %d data %d %d %x",
		host_index, clk.currTime(), idx, d.data.sop, d.data.eop, d.data.payload);
		endrule

		for (Integer j = 0; j < valueof(NUM_OF_ALTERA_PORTS); j = j + 1)
		begin
			rule add_to_correct_tx (correct_tx_index[i] == fromInteger(j));
				let d <- toGet(data_fifo[i]).get;
				tx_ring_buffer[j].write_request.put
					(makeWriteReq(d.data.sop, d.data.eop, d.data.payload));
			endrule
		end
    end

/*-------------------------------------------------------------------------------*/
                        // Manage Flow update requests
/*-------------------------------------------------------------------------------*/
    FIFO#(FlowUpdateT) flow_update_fifo <- mkSizedFIFO(valueof(DEFAULT_FIFO_LEN));

    for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
    begin
        rule enq_to_flow_update_fifo_rx;
            let d <- toGet(flow_update_fifo_rx[i]).get;
            flow_update_fifo.enq(d);
        endrule
    end

    rule enq_to_flow_update_fifo_tx;
        let d <- toGet(flow_update_fifo_tx).get;
        flow_update_fifo.enq(d);
    endrule

    rule update_flow_matrix;
        let d <- toGet(flow_update_fifo).get;

        if (d.op == 0) // remove flow
        begin
            mmf.removeFlow(d.src, d.dst, d.flow_id, d.seq_num);
            mmf.remFromFlowCountMatrix(d.src, d.dst);
        end

        else if (d.op == 1) // add flow
        begin
            mmf.addFlow(d.src, d.dst, d.flow_id, d.seq_num);
            mmf.addToFlowCountMatrix(d.src, d.dst, d.flow_id, d.seq_num);
        end
    endrule

/*-------------------------------------------------------------------------------*/
                            // MAC and DMA Req handlers
/*-------------------------------------------------------------------------------*/
    for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
    begin
        rule handle_rx_buffer_write_req_from_mac;
            let req <- toGet(mac_write_request_fifo[i]).get;
			if (req.data.sop == 1 && req.data.eop == 0)
				num_of_rxWrite_pkt_reg[i] <= num_of_rxWrite_pkt_reg[i] + 1;
            if (verbose)
                $display("[SCHED (%d)] CLK = %d Putting data into rx port buffer %d %d %x i = %d",
                host_index, clk.currTime(), req.data.sop, req.data.eop, req.data.payload, i);
			rx_ring_buffer[i].write_request.put
					  (makeWriteReq(req.data.sop, req.data.eop, req.data.payload));
        endrule

        rule handle_tx_buffer_read_req_from_mac;
            let req <- toGet(mac_read_request_fifo[i]).get;
            tx_ring_buffer[i].read_request.put(makeReadReq(req.op));
        endrule

        rule send_tx_buffer_read_res_to_mac;
            let d <- tx_ring_buffer[i].read_response.get;
            mac_read_response_fifo[i].enq(makeReadRes(d.data));
        endrule
    end

    rule handle_dma_simulator_write_req;
        let req <- toGet(dma_write_request_fifo).get;

        if (verbose)
            $display("[SCHED (%d)] Putting data into host tx buffer %d %d %x",
                        host_index, req.data.sop, req.data.eop, req.data.payload);

        ring_buffer[0].write_request.put
            (makeWriteReq(req.data.sop, req.data.eop, req.data.payload));
    endrule

    rule handle_dma_simulator_read_req;
        let req <- toGet(dma_read_request_fifo).get;
        src_rx_ring_buffer.read_request.put(makeReadReq(READ));
    endrule

    rule consume_pkt_in_response_to_dma_simulator_read_req;
        let d <- src_rx_ring_buffer.read_response.get;
		//debug_consuming_pkt_fifo.enq(d.data);
    endrule

/*-------------------------------------------------------------------------------*/
                      // Interface and Method definitions
/*-------------------------------------------------------------------------------*/
	Vector#(NUM_OF_ALTERA_PORTS, Put#(ReadReqType)) temp1;
	Vector#(NUM_OF_ALTERA_PORTS, Get#(ReadResType)) temp2;
	Vector#(NUM_OF_ALTERA_PORTS, Put#(WriteReqType)) temp3;
	Vector#(NUM_OF_ALTERA_PORTS, Get#(WriteResType)) temp4;

	for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
	begin
		temp1[i] = toPut(mac_read_request_fifo[i]);
		temp2[i] = toGet(mac_read_response_fifo[i]);
		temp3[i] = toPut(mac_write_request_fifo[i]);
		temp4[i] = toGet(mac_write_response_fifo[i]);
	end

	Vector#(NUM_OF_SERVERS, Get#(Vector#(RING_BUFFER_SIZE, Bit#(64)))) temp;
	for (Integer i = 0; i < valueof(NUM_OF_SERVERS); i = i + 1)
		temp[i] = toGet(fwd_queue_len_fifo[i]);

	method Action insertToSchedTable(ServerIndex index, IP ip_addr, MAC mac_addr);
		TableData d = TableData {
						server_ip : ip_addr,
						server_mac : mac_addr
		              };
		sched_table[index] <= d;
	endmethod

    method Action timeSlotsCount();
		time_slots_fifo.enq(num_of_time_slots_used_reg);
    endmethod

	method Action hostPktCount();
		host_pkt_fifo.enq(host_pkt_transmitted_reg);
	endmethod

	method Action nonHostPktCount();
		non_host_pkt_fifo.enq(non_host_pkt_transmitted_reg);
	endmethod

	method Action receivedPktCount();
		Bit#(64) pkt_received = 0;
		for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
			pkt_received = pkt_received + num_of_pkt_received_reg[i];
		received_pkt_fifo.enq(pkt_received);
	endmethod

	method Action rxWritePktCount();
		Bit#(64) rxWrite_pkt = 0;
		for (Integer i = 0; i < valueof(NUM_OF_ALTERA_PORTS); i = i + 1)
			rxWrite_pkt = rxWrite_pkt + num_of_rxWrite_pkt_reg[i];
		rxWrite_pkt_fifo.enq(rxWrite_pkt);
	endmethod

	method Action fwdQueueLen();
		for (Integer i = 0; i < valueof(NUM_OF_SERVERS); i = i + 1)
			enq_queue_length[i] <= 1;
	endmethod

	method Action start(ServerIndex serverIdx);
		curr_state <= RUN;
	    configure <= 1;
        start_scheduling_flag <= 0;
        start_polling_rx_buffer <= 0;
        start_tx_scheduling <= 0;
		host_index <= serverIdx;
	endmethod

	method Action stop();
		curr_state <= CONFIG;
        mmf.printMatrix(host_index);
	endmethod

    /* MAC interfaces */
    interface mac_read_request_port = temp1;
    interface mac_read_response_port = temp2;
    interface mac_write_request_port = temp3;
    interface mac_write_response_port = temp4;

    /* DMA simulator interface */
    interface Put dma_read_request = toPut(dma_read_request_fifo);
    interface Put dma_write_request = toPut(dma_write_request_fifo);
    interface Get dma_read_response = toGet(dma_read_response_fifo);
    interface Get dma_write_response = toGet(dma_write_response_fifo);

	interface Get time_slots_response = toGet(time_slots_fifo);
	interface Get host_pkt_response = toGet(host_pkt_fifo);
	interface Get non_host_pkt_response = toGet(non_host_pkt_fifo);
	interface Get received_pkt_response = toGet(received_pkt_fifo);
	interface Get rxWrite_pkt_response = toGet(rxWrite_pkt_fifo);
	interface fwd_queue_len = temp;
//	interface Get debug_consuming_pkt = toGet(debug_consuming_pkt_fifo);

endmodule
