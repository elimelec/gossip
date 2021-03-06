//
//  GSUserAgent.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/5/12.
//

#import "GSUserAgent.h"
#import "GSUserAgent+Private.h"
#import "GSCodecInfo.h"
#import "GSCodecInfo+Private.h"
#import "GSDispatch.h"
#import "Util.h"


@implementation GSUserAgent {
    GSConfiguration *_config;
    pjsua_transport_id _transportId;

    pj_caching_pool _cp;
    pj_pool_t *_gpool;
    //pjmedia_port *_tone_generator;
    pjmedia_snd_port *_inputOutput;
}

@synthesize account = _account;
@synthesize status = _status;

+ (GSUserAgent *)sharedAgent {
    static dispatch_once_t onceToken;
    static GSUserAgent *agent = nil;
    dispatch_once(&onceToken, ^{ agent = [[GSUserAgent alloc] init]; });
    
    return agent;
}


- (id)init {
    if (self = [super init]) {
        _account = nil;
        _config = nil;
        
        _gpool = nil;
        _tone_generator = nil;
        _inputOutput = nil;

        _transportId = PJSUA_INVALID_ID;
        _status = GSUserAgentStateUninitialized;
    }
    return self;
}

- (void)dealloc {
    if (_transportId != PJSUA_INVALID_ID) {
        pjsua_transport_close(_transportId, PJ_TRUE);
        _transportId = PJSUA_INVALID_ID;
    }

    if (_status >= GSUserAgentStateConfigured) {
        pjsua_destroy();
    }

    _account = nil;
    _config = nil;
    _status = GSUserAgentStateDestroyed;
}


- (GSConfiguration *)configuration {
    return _config;
}

- (GSUserAgentState)status {
    return _status;
}

- (void)setStatus:(GSUserAgentState)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self didChangeValueForKey:@"status"];
}


- (BOOL)configure:(GSConfiguration *)config {
    GSAssert(!_config, @"Gossip: User agent is already configured.");
    _config = [config copy];
    
    // create agent
    GSReturnNoIfFails(pjsua_create());
    [self setStatus:GSUserAgentStateCreated];
    
    // configure agent
    pjsua_config uaConfig;
    pjsua_logging_config logConfig;
    pjsua_media_config mediaConfig;
    
    pjsua_config_default(&uaConfig);
    [GSDispatch configureCallbacksForAgent:&uaConfig];

	unsigned long user_agent_string_length = _config.account.userAgent.length + 1;
	char *user_agent_string = malloc(sizeof(char) * (user_agent_string_length));
	BOOL stringConversionSuccess = [_config.account.userAgent getCString:user_agent_string maxLength:user_agent_string_length encoding:NSUTF8StringEncoding];

	if (stringConversionSuccess) {
		pj_str_t user_agent = {user_agent_string, user_agent_string_length - 1};
		uaConfig.user_agent = user_agent;
	} else {
		free(user_agent_string);
	}

    pjsua_logging_config_default(&logConfig);
    logConfig.level = _config.logLevel;
    logConfig.console_level = _config.consoleLogLevel;
    
    pjsua_media_config_default(&mediaConfig);
    mediaConfig.clock_rate = _config.clockRate;
    mediaConfig.snd_clock_rate = _config.soundClockRate;
    mediaConfig.ec_tail_len = config.echoCancelationTail;
    mediaConfig.no_vad = config.disableVAD ? 1 : 0;
	mediaConfig.enable_ice = 1;
    
    GSReturnNoIfFails(pjsua_init(&uaConfig, &logConfig, &mediaConfig));
    
    // Configure the DNS resolvers to also handle SRV records
    if (config.enableSRV) {
        pjsip_endpoint* endpoint = pjsua_get_pjsip_endpt();
        pj_dns_resolver* resolver;
        pj_str_t google_dns = [GSPJUtil PJStringWithString:@"8.8.8.8"];
        struct pj_str_t servers[] = { google_dns };
        GSReturnNoIfFails(pjsip_endpt_create_resolver(endpoint, &resolver));
        GSReturnNoIfFails(pj_dns_resolver_set_ns(resolver, 1, servers, nil));
        GSReturnNoIfFails(pjsip_endpt_set_resolver(endpoint, resolver));
    }
    
    // create UDP transport
    // TODO: Make configurable? (which transport type to use/other transport opts)
    // TODO: Make separate class? since things like public_addr might be useful to some.
    pjsua_transport_config transportConfig;
    pjsua_transport_config_default(&transportConfig);
    transportConfig.port = 5060;
    
    switch (_config.qosType) {
        case GSQOSTypeBestEffort: transportConfig.qos_type = PJ_QOS_TYPE_BEST_EFFORT; break;
        case GSQOSTypeBackground: transportConfig.qos_type = PJ_QOS_TYPE_BACKGROUND; break;
        case GSQOSTypeVideo: transportConfig.qos_type = PJ_QOS_TYPE_VIDEO; break;
        case GSQOSTypeVoice: transportConfig.qos_type = PJ_QOS_TYPE_VOICE; break;
        case GSQOSTypeControl: transportConfig.qos_type = PJ_QOS_TYPE_CONTROL; break;
    }

    switch (_config.transportType) {
        case GSUDPTransportType:
		case GSUDP6TransportType:
			[self createTransport:PJSIP_TRANSPORT_UDP transportConfig:transportConfig];
			[self createTransport:PJSIP_TRANSPORT_UDP6 transportConfig:transportConfig];
			break;

        case GSTCPTransportType:
		case GSTCP6TransportType:
			[self createTransport:PJSIP_TRANSPORT_TCP transportConfig:transportConfig];
			[self createTransport:PJSIP_TRANSPORT_TCP6 transportConfig:transportConfig];
			break;

        case GSTLSTransportType:
		case GSTLS6TransportType:
			[self createTransport:PJSIP_TRANSPORT_TLS transportConfig:transportConfig];
			[self createTransport:PJSIP_TRANSPORT_TLS6 transportConfig:transportConfig];
			break;
    }

	[self setStatus:GSUserAgentStateConfigured];

    // configure account
    _account = [[GSAccount alloc] init];
    return [_account configure:_config.account];
}

- (BOOL) createTransport:(pjsip_transport_type_e) transportType transportConfig:(pjsua_transport_config) transportConfig{
    pj_status_t status = (pjsua_transport_create(transportType, &transportConfig, &_transportId));
    if (status != PJ_SUCCESS) {
        pjsua_transport_config_default(&transportConfig);
        transportConfig.port = 0;
        GSReturnNoIfFails(pjsua_transport_create(transportType, &transportConfig, &_transportId));
    }
	return YES;
}


- (BOOL)start {
    GSReturnNoIfFails(pjsua_start());
    [self setStatus:GSUserAgentStateStarted];

    [self initializeToneGenerator];

    return YES;
}


- (void) initializeToneGenerator{
    if(self.status == GSUserAgentStateStarted)
	{
		pj_caching_pool_init(&_cp, &pj_pool_factory_default_policy, 0);
		_gpool = pj_pool_create(&_cp.factory, "app", 4000, 4000, NULL);
		pjmedia_tonegen_create(_gpool, 8000, 1, 160, 16, 0, &_tone_generator);

		pjmedia_snd_port_create_player(_gpool, 0, 8000, 1, 160, 16, 0, &_inputOutput);

		// When you minimize the app right after you start it, _inputOutput is nil,
		// which will cause an assertion error on pjmedia_snd_port_connect call (which checks for not null parameters).
		if (!_inputOutput || !_tone_generator)
		{
			return;
		}

		pjmedia_snd_port_connect(_inputOutput, _tone_generator);
	}
}


- (BOOL)reset {
    [_account disconnect];

    [[NSNotificationCenter defaultCenter] removeObserver:_account];

    // tone generator
    if(_tone_generator) {
        pjmedia_port_destroy(_tone_generator);
        _tone_generator = nil;
    }
    if(_inputOutput) {
        pjmedia_snd_port_disconnect(_inputOutput);
		pjmedia_snd_port_destroy(_inputOutput);
        _inputOutput = nil;
    }
    if(_gpool) {
        pj_pool_release(_gpool);
        _gpool = nil;
    }
    if(_cp.lock)
        pj_caching_pool_destroy(&_cp);


    // needs to nil account before pjsua_destroy so pjsua_acc_del succeeds.
    _transportId = PJSUA_INVALID_ID;
    _account = nil;
    _config = nil;
    NSLog(@"Destroying...");
    GSReturnNoIfFails(pjsua_destroy());
    [self setStatus:GSUserAgentStateDestroyed];
    return YES;
}


- (NSArray *)arrayOfAvailableCodecs {
    GSAssert(!!_config, @"Gossip: User agent not configured.");
    
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    
    unsigned int count = 255;
    pjsua_codec_info codecs[count];
    GSReturnNilIfFails(pjsua_enum_codecs(codecs, &count));
    
    for (int i = 0; i < count; i++) {
        pjsua_codec_info pjCodec = codecs[i];
        
        GSCodecInfo *codec = [GSCodecInfo alloc];
        codec = [codec initWithCodecInfo:&pjCodec];
        [arr addObject:codec];
    }
    
    return [NSArray arrayWithArray:arr];
}

@end
