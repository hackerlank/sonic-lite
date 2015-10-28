import DefaultValue::*;

typedef 9 KEY_LEN;
typedef 32 VALUE_LEN;
typedef 128 TABLE_LEN;
typedef 1024 BCAM_TABLE_LEN;
typedef 20 ADDR_LEN; //log(TABLE_LEN * (KEY_LEN+VALUE_LEN))

/* if you change this value, also make sure to change 
 * priority_encoder() and flip_bit_at_pos() functions
 * in MatchTable.bsv file.
*/
typedef 8 TABLE_ASSOCIATIVITY; // a match table consists of 8 hash tables

typedef Bit#(KEY_LEN) Key;
typedef Bit#(VALUE_LEN) Value;
typedef Bit#(11) AddrIndex; //XXX log(TABLE_LEN)
typedef Bit#(ADDR_LEN) Address;

typedef enum {GET, PUT, UPDATE, REMOVE, NONE} Operation deriving(Bits, Eq);
typedef enum {VALID, INVALID} Tag deriving(Bits, Eq);

typedef struct {
    Key key;
    Value value;
    Tag valid;
} Data deriving(Bits, Eq);

typedef struct {
    Key key;
    Value value;
    Operation op;
    AddrIndex addrIdx;
} RequestType deriving(Bits, Eq);

instance DefaultValue#(RequestType);
    defaultValue = RequestType {
                                key : 0,
                                value : 0,
                                op : NONE,
                                addrIdx : 0
                               };
endinstance

function RequestType makeRequest(Key key, Value value, Operation op);
    return RequestType {
                        key : key,
                        value : value,
                        op : op,
                        addrIdx : 0
                       };
endfunction

typedef struct {
    Key key;
    Value value;
    Operation op;
    AddrIndex addrIdx;
    Tag tag; //INVALID if operation failed
} ResponseType deriving(Bits, Eq);

instance DefaultValue#(ResponseType);
    defaultValue = ResponseType {
                                key : 0,
                                value : 0,
                                addrIdx : 0,
                                op : NONE,
                                tag : INVALID
                               };
endinstance

function ResponseType 
    makeResponse(Key key, Value value, AddrIndex addrIdx, Operation op, Tag tag);
    return ResponseType {
                         key : key,
                         value : value,
                         addrIdx : addrIdx,
                         op : op,
                         tag : tag
                        };
endfunction

