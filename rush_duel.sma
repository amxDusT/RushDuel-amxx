#include < amxmodx >
#include < amxmisc >
#include < fakemeta >
#include < hamsandwich >
#include < regex >
#include < orpheu >
#include < orpheu_stocks >
#include < xs >


//#define TEAM_PLUGIN         // if you have teamprotection plugin
//#define SQL               // if you want to have a ranking system through sql

#define ADMIN_FLAG          ADMIN_LEVEL_A
#define PREFIX              "^3[RUSH]^1"
#define SLAY_PLAYERS_TIME   9.0
#define MAX_ZONES           4

#if defined SQL
    #include < sqlx >
#endif

#if defined TEAM_PLUGIN
    /** 
    * Pauses/Unpauses teams
    * 
    * @note     teams don't get removed. You will show as team.
    *
    * @param id         player1 id.
    * @param id2        player2 id.
    * @param unpause    if to unpause teams  
    */
    native kf_pause_teaming(id, id2, unpause = 0);
#endif

#define set_bit(%1,%2)      (%1 |= (1<<(%2&31)))
#define clear_bit(%1,%2)    (%1 &= ~(1<<(%2&31)))
#define check_bit(%1,%2)    (%1 & (1<<(%2&31)))

#define VERSION "2.0"
#define AUTHOR  "DusT"

new const TOTAL = 2;
new const SPRITE_BEAM[] = "sprites/laserbeam.spr";

#if defined SQL
new const host[] = "127.0.0.1";
new const user[] = "root";
new const pass[] = "";
new const db[]   = "mysql_dust";

new g_total;
new Handle:g_Tuple;
new bool:b_ResetRanks;

enum _:taskData
{
    PINDB   = 0,
    PDUELS,
    PWON,
    PLOST,
    PWON1,
    PWON2,
    PWON3,
    PRANK
}

new g_pInfo[ MAX_PLAYERS + 1 ][ taskData ];
#endif

#if AMXX_VERSION_NUM < 183
    set_fail_state( "Plugin requires 1.8.3 or higher." );
#endif



enum _:TASKS ( += 1000 )
{
    TASK_DRAW = 141,
    TASK_COUNTDOWN,
    TASK_AUTOKILL,
    TASK_RESTART,
    TASK_REVIVE,
    TASK_STOP
}

enum _:attType
{
    SLASH   = 0,
    STAB    = 1,
    BOTH    = 2
}

enum _:rushData
{
    PLAYER1,
    PLAYER2,
    RUSHTYPE,
}

new hasDisabledRush;
new hasBlocked[ MAX_PLAYERS + 1 ];
new bool:canRush;
new rushDir[ 128 ];
new activeZones;
new busyZones;

new bHasTouch;
new bIsOver; 
new bIsInRush, bCanRun;
new g_RushInfo[ MAX_ZONES ][ rushData ]; 
new g_Rounds[ MAX_ZONES ][ 3 ];
new Float:g_HealthCache[ MAX_ZONES ][ 2 ];
new bIsZoneBusy;

new beam;
new editor, edit_zone;

new Float:g_vecOrigin[ MAX_ZONES ][ 2 ][ 3 ];
new Float:g_Velocity [ MAX_ZONES ][ 2 ][ 3 ];

new const DisableAccess = ( 1 << 26 );

new HamHook:PostKilled;
new HamHook:PreKilled;
new HamHook:PlayerTouch;
//new HamHook:PlayerThink; // for some reason this doesn't work, so imma use fakemeta
new PlayerThink;

new OrpheuStruct:ppmove;

new Float:pHealth[ attType ];
new pRounds;
new pAlive;

public plugin_init()
{
    register_plugin( "Rush Duel", VERSION, AUTHOR );

    register_cvar( "AmX_DusT", "Rush_Duel", FCVAR_SPONLY | FCVAR_SERVER );

    register_clcmd( "amx_rush_menu", "AdminRush", ADMIN_FLAG );

    register_clcmd( "say /rush", "CmdRush" );
    register_clcmd( "say /stop", "CmdStopDuel" );

    bind_pcvar_float( create_cvar( "rush_health_slash", "1" ), Float:pHealth[ SLASH ] );
    bind_pcvar_float( create_cvar( "rush_health_stab",  "35"), Float:pHealth[ STAB ]  );
    bind_pcvar_float( create_cvar( "rush_health_both",  "35"), Float:pHealth[ BOTH ]  );

    bind_pcvar_num( create_cvar( "rush_rounds", "10" ), pRounds );
    /*
        Explanation rush_alive:
            - 0: revives who made most kills. In case of draw, both revive.
            - 1: revives who made most kills. In case of draw, both dead.
            - 2: revives who killed the player on last round. 
            - 3: both revive.
    */
    bind_pcvar_num( create_cvar( "rush_alive", "0", .description="Info on github.com/amxDust/RushDuel-amxx"), pAlive );
    DisableHamForward( PreKilled   = RegisterHamPlayer( Ham_Killed, "fw_PlayerKilled_Post", 1 ) ); 
    DisableHamForward( PostKilled  = RegisterHamPlayer( Ham_Killed, "fw_PlayerKilled_Pre",  0 ) ); 
    //DisableHamForward( PlayerThink = RegisterHamPlayer( Ham_Think,  "fw_PlayerThink_Pre",   0 ) );
    DisableHamForward( PlayerTouch = RegisterHamPlayer( Ham_Touch,  "fw_PlayerTouch" ) );

    //PlayerThink = register_forward( FM_PlayerPreThink, "fw_PlayerThink_Pre" );

    OrpheuRegisterHook( OrpheuGetFunction( "PM_Duck" ), "OnPM_Duck" );
    OrpheuRegisterHook( OrpheuGetFunction( "PM_Jump" ), "OnPM_Jump" );
    OrpheuRegisterHook( OrpheuGetDLLFunction( "pfnPM_Move", "PM_Move" ), "OnPM_Move" );

    activeZones = CountZones();

    //to_remove
    canRush = true;
}

public plugin_precache()
{
    beam = precache_model( SPRITE_BEAM );
}

public client_disconnected( id )
{
    if( task_exists( id + TASK_REVIVE ) )
        remove_task( id + TASK_REVIVE );
    
    if( check_bit( bIsInRush, id ) )
        StopDuelPre( GetZone( id ), false, id );
    
}

public AdminRush( id, level, cid )
{
    if( !cmd_access( id, level, cid, 0 ) )
        return PLUGIN_HANDLED;
    
    AdminRushMenu( id );
    
    return PLUGIN_HANDLED;
}

AdminRushMenu( id )
{
    new menuid = menu_create( fmt( "\rRush Menu^n\yAdmin Menu^n^nCurrent Active Zones: %d", activeZones ), "AdminRushHandler" );
    
    menu_additem( menuid, "Create New Zone", _, activeZones >= MAX_ZONES? DisableAccess:0 );

    menu_additem( menuid, "Edit Existing Zone", _, activeZones <= 0? DisableAccess:0 );

    menu_display(id, menuid );

    return PLUGIN_HANDLED;
}

public AdminRushHandler( id, menuid, item )
{
    if( is_user_connected( id ) && item != MENU_EXIT )
    {
        switch( item )
        {
            case 0: EditZone( id, activeZones++ );
            
            case 1: EditZoneMenu( id );
        }
    }

    menu_destroy( menuid );
    return PLUGIN_HANDLED;
} 

public CmdStopDuel( id )
{
    if( task_exists( id + TASK_REVIVE ) )
        remove_task( id + TASK_REVIVE );
    if( check_bit( bIsInRush, id ) )
        StopDuelPre( GetZone( id ), false, id );
}

public CmdRush( id )
{
    new menuid = menu_create( "Rush Menu", "CmdRushHandler" );

    menu_additem( menuid, "Rush" );
    menu_additem( menuid, "Block Player" );

    menu_additem( menuid, check_bit( hasDisabledRush, id )? "ENABLE Requests":"DISABLE Requests" );

    menu_display( id, menuid );

    return PLUGIN_HANDLED;
}

public CmdRushHandler( id, menuid, item )
{
    if( is_user_connected( id ) && item != MENU_EXIT )
    {
        switch( item ) 
        {
            case 0:
            {
                RushMenu( id );
            }
            case 1:
            {
                BlockMenu( id );
            }
            case 2:
            {
                if( check_bit( hasDisabledRush, id ) )
                    clear_bit( hasDisabledRush, id );
                else
                    set_bit( hasDisabledRush, id );
                
                CmdRush( id );
            }
        }
    }

    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

BlockMenu( id )
{
    new players[ 32 ], iNum;

    get_players( players, iNum );
    
    new menuid = menu_create( "Block Menu", "BlockMenuHandler" );
    new buff[ 2 ];
    // using "e" flag on get_players doesn't work always fine.
    for( new i; i < iNum; i++ )
    {                                                                                                          //spectator
        if( id == players[ i ] || get_user_team( id ) == get_user_team( players[ i ] ) || get_user_team( players[ i ] ) == 3 )
            continue;

        buff[ 0 ] = players[ i ];
        buff[ 1 ] = 0;
        menu_additem( menuid, fmt( "%n%s", buff[ 0 ], check_bit( hasBlocked[ id ], buff[ 0 ] )? " [UNBLOCK]":"" ), buff );
    } 

    menu_display( id, menuid );
}

public BlockMenuHandler( id, menuid, item )
{
    if( is_user_connected( id ) && item != MENU_EXIT )
    {
        new buff[ 2 ]
        menu_item_getinfo( menuid, item, _, buff, charsmax( buff ) );
        
        if( is_user_connected( buff[ 0 ] ) )
        {
            if( check_bit( hasBlocked[ id ], buff[ 0 ] ) )
                clear_bit( hasBlocked[ id ], buff[ 0 ] );
            else
                set_bit( hasBlocked[ id ], buff[ 0 ] );
        }

        BlockMenu( id );
    }
    
    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

public RushMenu( id )
{
    if( !CanPlayerRush( id ) )
        return PLUGIN_HANDLED;
    
    new players[ 32 ], num;

    get_players( players, num, "ach" );
    
    new menuid = menu_create( "\rRush Menu^n\yChoose a Player", "RushMenuHandler" );
    new bool:hasPlayers, buff[ 2 ];
    for( new i; i < num; i++ )
    {
        if( id == players[ i ] || get_user_team( id ) == get_user_team( players[ i ] ) || get_user_team( players[ i ] ) == 3 || check_bit( bIsInRush, players[ i ] ) )
            continue;

        buff[ 0 ] = players[ i ];
        buff[ 1 ] = 0;

        if( !hasPlayers )
            hasPlayers = true;

        menu_additem( menuid, fmt( "%n", buff[ 0 ] ), buff );
    }
    if( !hasPlayers )
    {
        client_print_color( id, print_team_red, "%s There are no players to rush with!", PREFIX );
        return PLUGIN_HANDLED;
    }

    menu_display( id, menuid );
    return PLUGIN_HANDLED;
}

public RushMenuHandler( id, menuid, item )
{
    if( CanPlayerRush( id ) && item != MENU_EXIT )
    {
        new buff[ 2 ]
        menu_item_getinfo( menuid, item, _, buff, charsmax( buff ) );

        if( CanPlayerRush( id, true, buff[ 0 ] ) )
        {
            new menuid2 = menu_create( "Choose Rush Type", "RushTypeHandler" );
            menu_additem( menuid2, "Only Slash ( R1 )", buff );
            menu_additem( menuid2, "Only Stab  ( R2 )" );
            menu_additem( menuid2, "Both ( R1 and R2 )" );

            menu_display( id, menuid2 );
        }
    }

    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

public RushTypeHandler( id, menuid, item )
{
    if( CanPlayerRush( id ) && item != MENU_EXIT )
    {
        new buff[ 2 ];
        menu_item_getinfo( menuid, 0, _, buff, charsmax( buff ) );

        if( CanPlayerRush( id, true, buff[ 0 ] ) )
        {
            new menuid2 = menu_create( fmt( "\y'%n' wants to rush %s with you!^nAccept?", id, item == 0? "only SLASH(R1)":item == 1? "only STAB(R2)":"(R1 and R2)" ), "SendChallengeHandler" );
            new buffer[ 3 ];
            buffer[ 0 ] = id;
            buffer[ 1 ] = item;
            buffer[ 2 ] = 0;
            menu_additem( menuid2, "Accept", buffer );
            menu_additem( menuid2, "Refuse" );

            menu_display( buff[ 0 ], menuid2, _, 10 );
        }
    }

    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

public SendChallengeHandler( id, menuid, item )
{
    if( CanPlayerRush( id , false ) && item == 0 )
    {
        new buff[ 3 ];
        menu_item_getinfo( menuid, 0, _, buff, charsmax( buff ) );
        if( CanPlayerRush( id, true, buff[ 0 ] ) )
        {
            client_print_color( id, print_team_red, "%s You accepted %n's challenge.", PREFIX, buff[ 0 ] );
            client_print_color( id, print_team_red, "%s %n accepted your challenge.", PREFIX, id );
            GetReady( buff[ 0 ], id, buff[ 1 ] );
        }
    }
    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

GetReady( id, pid, type )
{
    new i;
    for( i = 0; i < activeZones; i++ )
    {
        if( !check_bit( bIsZoneBusy, i ) )
            break;
        
        if( i == activeZones - 1 )
        {
            client_print_color( id, print_team_red, "%s There are no free zones to play. Retry later.", PREFIX );
            return;
        }
    }
    // unfinished_
    #if defined SQL
        IsInDb( id,  0 );
        IsInDb( pid, 0 );
    #endif 
    #if defined TEAM_PLUGIN
        kf_pause_teaming( id, pid );
    #endif

    g_RushInfo[ i ][ PLAYER1 ]  = id;
    g_RushInfo[ i ][ PLAYER2 ]  = pid;
    g_RushInfo[ i ][ RUSHTYPE ] = type;
    
    g_Rounds[ i ][ PLAYER1 ] = 0;
    g_Rounds[ i ][ PLAYER2 ] = 0;
    g_Rounds[ i ][ TOTAL ]   = 1;

    set_bit( bIsInRush, id );
    set_bit( bIsInRush, pid );

    if( !busyZones )
        ToggleFwds( true );

    set_bit( bIsZoneBusy, i );
    busyZones++;

    pev( id,  pev_health, g_HealthCache[ i ][ PLAYER1 ] );
    pev( pid, pev_health, g_HealthCache[ i ][ PLAYER2 ] );

    set_pev( id,  pev_health, pHealth[ type ] );
    set_pev( pid, pev_health, pHealth[ type ] );
    
    TeleportPlayer( id,  i, PLAYER1 );
    TeleportPlayer( pid, i, PLAYER2 );

    LookAtOrigin( id,  g_vecOrigin[ i ][ PLAYER2 ] );
    LookAtOrigin( pid, g_vecOrigin[ i ][ PLAYER1 ] );

    new params[ 1 ];
    params[ 0 ] = 3; 
    set_task( 1.2, "CountDown", TASK_COUNTDOWN + i, params, 1 ); 
    set_task( SLAY_PLAYERS_TIME, "SlayPlayers", TASK_AUTOKILL + i );

}

public ReviveDead( id )
{
    id -= TASK_REVIVE;
    if( check_bit( bIsInRush, id ) && !check_bit( bIsOver, id ) )
        ExecuteHamB( Ham_CS_RoundRespawn, id );
}

// unfinished__
public ContinueRounds( zone )
{
    zone -= TASK_RESTART;

    if( check_bit( bIsOver, zone ) )    
        return;

    TeleportPlayer( g_RushInfo[ zone ][ PLAYER1 ], zone, PLAYER1 );
    TeleportPlayer( g_RushInfo[ zone ][ PLAYER2 ], zone, PLAYER2 );

    LookAtOrigin( g_RushInfo[ zone ][ PLAYER1 ], g_vecOrigin[ zone ][ PLAYER2 ] );
    LookAtOrigin( g_RushInfo[ zone ][ PLAYER2 ], g_vecOrigin[ zone ][ PLAYER1 ] );

    set_pev( g_RushInfo[ zone ][ PLAYER1 ], pev_health, pHealth[ g_RushInfo[ zone ][ RUSHTYPE ] ] );
    set_pev( g_RushInfo[ zone ][ PLAYER2 ], pev_health, pHealth[ g_RushInfo[ zone ][ RUSHTYPE ] ] );

    if( task_exists( TASK_AUTOKILL + zone ) )
        remove_task( TASK_AUTOKILL + zone );

    new params[ 1 ];
    params[ 0 ] = 1;
    set_task( 1.2, "CountDown", TASK_COUNTDOWN + zone, params, 1 ); 
    set_task( SLAY_PLAYERS_TIME, "SlayPlayers", TASK_AUTOKILL + zone );
}

public SlayPlayers( zone )
{
    zone -= TASK_AUTOKILL;

    client_print_color( g_RushInfo[ zone ][ PLAYER1 ], print_team_red, "%s You took too much", PREFIX );
    client_print_color( g_RushInfo[ zone ][ PLAYER2 ], print_team_red, "%s You took too much", PREFIX );

    g_Rounds[ zone ][ TOTAL ]++;

    user_kill( g_RushInfo[ zone ][ PLAYER1 ] );
    user_kill( g_RushInfo[ zone ][ PLAYER2 ] );

}
public CountDown( params[], zone )
{
    zone -= TASK_COUNTDOWN;

    new p1 = g_RushInfo[ zone ][ PLAYER1 ];
    new p2 = g_RushInfo[ zone ][ PLAYER2 ];

    if( !is_user_alive( p1 ) || !is_user_alive( p2 ) )
        return;

    new time = --params[ 0 ];
    
    if( time > 0 )
    {

        set_hudmessage( 0, 255, 0, .holdtime = 1.0, .channel = -1 );

        if( time == 2 )
        {
            show_hudmessage( p1, "Knife Rush^nREADY" );
            show_hudmessage( p2, "Knife Rush^nREADY" );

            client_cmd( p1, "spk ready" );
            client_cmd( p2, "spk ready" );
        }
        else
        {
            show_hudmessage( p1, "Knife Rush^nSTEADY" );
            show_hudmessage( p2, "Knife Rush^nSTEADY" );
        }
        
        set_task( 1.2, "CountDown", TASK_COUNTDOWN + zone, params, 1 ); 
    }
    else
    {

        set_hudmessage( 0, 255, 0, .holdtime = 3.0, .channel = -1 );

        show_hudmessage( p1, "Knife Rush^nFIGHT!" );
        show_hudmessage( p2, "Knife Rush^nFIGHT!" );

        client_cmd( p1, "spk ^"/sound/hgrunt/fight!^"" );
        client_cmd( p2, "spk ^"/sound/hgrunt/fight!^"" );

        set_bit( bCanRun, p1 );
        set_bit( bCanRun, p2 );
    }
}

TeleportPlayer( id, zone, position )
{
    set_pev( id, pev_velocity, Float:{ 0.0, 0.0, 0.0 } );
    set_pev( id, pev_origin, g_vecOrigin[ zone ][ position ] );
    
    new Float:distance = get_distance_f( g_vecOrigin[ zone ][ position ], g_vecOrigin[zone][ 1 - position ] );

    new Float:vector[ 3 ];

    vector[ 0 ] = ( ( g_vecOrigin[ zone ][ 1 - position ][ 0 ] - g_vecOrigin[ zone ][ position ][ 0 ] ) / distance );
    vector[ 1 ] = ( ( g_vecOrigin[ zone ][ 1 - position ][ 1 ] - g_vecOrigin[ zone ][ position ][ 1 ] ) / distance );
    vector[ 2 ] = ( ( g_vecOrigin[ zone ][ 1 - position ][ 2 ] - g_vecOrigin[ zone ][ position ][ 2 ] ) / distance );

    static Float:multiplier = 250.0;
    //( multiplier || multiplier = 250.0 );

    g_Velocity[ zone ][ position ][ 0 ] = vector[ 0 ] * multiplier;
    g_Velocity[ zone ][ position ][ 1 ] = vector[ 1 ] * multiplier;
    g_Velocity[ zone ][ position ][ 2 ] = vector[ 2 ] * multiplier;
    
    for( new i; i < 3; i++ )
        client_print_color( id, print_team_red, "%s %s ^4allowed^1. Round: ^4%d^1.", PREFIX, g_RushInfo[ zone ][ 2 ] == BOTH? "Both Slash (R1) and Stab (R2) are":g_RushInfo[ zone ][ 2 ] == SLASH? "Only SLASH (R1) is":"Only STAB (R2) is", g_Rounds[ zone ][ TOTAL ] );
}

ToggleFwds( bool:enable )
{
    if( enable )
    {
        EnableHamForward( PreKilled   );
        EnableHamForward( PostKilled  );
        //EnableHamForward( PlayerThink );
        EnableHamForward( PlayerTouch );

        PlayerThink = register_forward( FM_PlayerPreThink, "fw_PlayerThink_Pre" );
    }
    else
    {
        DisableHamForward( PreKilled   );
        DisableHamForward( PostKilled  );
        //DisableHamForward( PlayerThink );
        DisableHamForward( PlayerTouch );

        unregister_forward( FM_PlayerPreThink, PlayerThink );
    }
}

bool:CanPlayerRush( id, bool:message = true, player=0 )
{
    if( !is_user_connected( id ) )
        return false;

    if( !canRush )
    {
        if( message )
            client_print_color( id, print_team_red, "%s Rush Plugin is not available right now. Retry in few seconds.", PREFIX );
        return false;
    }
    else if( !activeZones )
    {
        if( message )
            client_print_color( id, print_team_red, "%s This map has no zones available", PREFIX );
        return false;
    }
    else if( busyZones >= activeZones )
    {
        if( message )
            client_print_color( id, print_team_red, "%s There are no free zones to play. Retry later.", PREFIX );
        return false;
    }
    else if( player )
    {
        if( !is_user_connected( player ) )
        {
            if( message )
                client_print_color( id, print_team_red, "%s Player is not connected.", PREFIX );
            return false;
        }
        else if( !is_user_alive( player ) )
        {
            if( message )
                client_print_color( id, print_team_red, "%s Player is not alive.", PREFIX );
            return false;
        }
        else if( check_bit( bIsInRush, player ) )
        {
            if( message )
                client_print_color( id, print_team_red, "%s Player is already in a challenge.", PREFIX );
            return false;
        }
        else if( get_user_team( id ) == get_user_team( player ) )
        {
            if( message )
                client_print_color( id, print_team_red, "%s You can't challenge a teammate.", PREFIX );
            return false;
        }
    }
    else if( !is_user_alive( id ) )
    {
        if( message )
            client_print_color( id, print_team_red, "%s You must be alive in order to access ^4Rush Menu", PREFIX );
        return false;
    }
    else if( check_bit( bIsInRush, id ) )
    {
        if( message )
            client_print_color( id, print_team_red, "%s You are already in a challenge", PREFIX );
        return false;
    }
    

    return true;
}

public fw_PlayerThink_Pre( id )
{
    //client_print( id, print_chat, "%d %d", check_bit( bIsInRush, id ), check_bit( bCanRun, id ) );
    if( check_bit( bIsInRush, id ) && check_bit( bCanRun, id ) )
    {
        //client_print( id, print_chat, "hello" ); 
        new zone = GetZone( id );
        new pos  = GetPos ( id, zone );

        set_pev( g_RushInfo[ zone ][ pos ], pev_velocity, g_Velocity[ zone ][ pos ] );

        switch( g_RushInfo[ zone ][ RUSHTYPE ] )
        {
            case STAB:
            {
                new btn = pev( id, pev_button );
                if( btn & IN_ATTACK )
                {
                    set_pev( id, pev_button, ( btn & ~IN_ATTACK ) | IN_ATTACK2 );
                } 
            }
            case SLASH:
            {
                new btn = pev( id, pev_button );
                if( btn & IN_ATTACK2 )
                {
                    set_pev( id, pev_button, ( btn & ~IN_ATTACK2 ) | IN_ATTACK );
                }
            }
        }
    }
}

public fw_PlayerKilled_Post( victim, killer )
{
    if( check_bit( bIsInRush, victim ) )
    {
        new zone = GetZone( victim );
        new pos  = GetPos ( victim, zone );
        

        clear_bit( bCanRun, victim );
        clear_bit( bCanRun, g_RushInfo[ zone ][ 1 - pos ] );
        clear_bit( bHasTouch, zone );

        if( task_exists( zone + TASK_AUTOKILL ) )
            remove_task( zone + TASK_AUTOKILL );
        
        if( check_bit( bIsOver, zone ) )
            return;

        if( victim != killer )
        {
            g_Rounds[ zone ][ 1 - pos ]++;
            g_Rounds[ zone ][ TOTAL ]++;
            client_print_color( killer, print_team_red, "%s You won this round. [ %d / %d ]", PREFIX, g_Rounds[ 1 - pos ], pRounds );
        }
        
        if( g_Rounds[ zone ][ TOTAL ] <= pRounds )
        {
            client_print_color( victim, print_team_red, "%s You lost this round. [ %d / %d ]", PREFIX, g_Rounds[ pos ], pRounds );
            if( task_exists( zone + TASK_RESTART ) )
                remove_task( zone + TASK_RESTART );
            
            set_task( 0.1, "ReviveDead", victim + TASK_REVIVE );
            set_task( 0.5, "ContinueRounds", zone + TASK_RESTART );
        }
        else
            StopDuelPre( zone );
    }

}

public fw_PlayerTouch( ent, id ){
    if( check_bit( bIsInRush, id ) && ent != 0 )
    {
        new zone = GetZone( id );
        if( !check_bit( bHasTouch, zone ) )
            set_bit( bHasTouch, zone );
    }
    return HAM_IGNORED
}

public fw_PlayerKilled_Pre( victim, killer )
{
    static msgCorpse;
    if( check_bit( bIsInRush, victim ) )
    {
        if( msgCorpse || ( msgCorpse = get_user_msgid( "ClCorpse" ) ) )
            set_msg_block( msgCorpse, BLOCK_ONCE );
        return HAM_HANDLED;
    }
    return HAM_IGNORED;
}

StopDuelPre( zone, bool:isOver = true, id = 0 )
{
    set_bit( bIsOver, zone );
    new p1 = g_RushInfo[ zone ][ PLAYER1 ];
    new p2 = g_RushInfo[ zone ][ PLAYER2 ];
    new r1 = g_Rounds[ zone ][ PLAYER1 ];
    new r2 = g_Rounds[ zone ][ PLAYER2 ];
    if( !isOver )
    {
        if( task_exists( zone + TASK_RESTART ) )
            remove_task( zone + TASK_RESTART );

        if( task_exists( zone + TASK_AUTOKILL ) )
            remove_task( zone + TASK_AUTOKILL );

        if( task_exists( zone + TASK_COUNTDOWN ) )
            remove_task( zone + TASK_COUNTDOWN );
        
        if( is_user_connected( id ) )
        {   
            user_silentkill( id, 0 );
            client_print_color( id, print_team_red, "%s You left the challenge. You lost!", PREFIX );
        }
            

        if( id == p1 )
        {
            ExecuteHamB( Ham_CS_RoundRespawn, p2 );
            client_print_color( p2, print_team_red, "%s Player left the challenge. You won!", PREFIX );
        }
        else
        {
            ExecuteHamB( Ham_CS_RoundRespawn, p1 );
            client_print_color( p1, print_team_red, "%s Player left the challenge. You won!", PREFIX );
        }
        new param[ 2 ];
        param[ 0 ] = ( ( id == p2 )? p2:p1 );
        set_task( 0.9, "StopDuel", zone + TASK_STOP, param, 2 );
        return;   
    }

    new result;
    new param[ 2 ];
    if( r1 < r2 )
        result = 1;
    else if( r1 == r2 )
        result = 2;

    switch( pAlive )
    {
        case 0, 1:
        {
            switch( result )
            {
                case 0:
                {
                    ExecuteHamB( Ham_CS_RoundRespawn, p1 );
                    param[ 0 ] = p2;
                    if( is_user_alive( p2 ) )
                        user_silentkill( p2, 0 );
                }
                case 1: 
                {
                    ExecuteHamB( Ham_CS_RoundRespawn, p2 );
                    param[ 0 ] = p1;
                    if( is_user_alive( p1 ) )
                        user_silentkill( p1, 0 );
                }
                case 2:
                {
                    if( pAlive )
                    {
                        if( is_user_alive( p1 ) )
                            user_silentkill( p1, 0 );
                        if( is_user_alive( p2 ) )
                            user_silentkill( p2, 0 );

                        param[ 0 ] = p1;
                        param[ 1 ] = p2;
                    }
                    else
                    {   
                        ExecuteHamB( Ham_CS_RoundRespawn, p1 );
                        ExecuteHamB( Ham_CS_RoundRespawn, p2 );
                    }
                }
            }
        }
        case 2:
        {
            if( is_user_alive( p1 ) )
            {
                ExecuteHamB( Ham_CS_RoundRespawn, p1 );
            }
            else
                param[ 0 ] = p1;
            if( is_user_alive( p2 ) )
            {   
                ExecuteHamB( Ham_CS_RoundRespawn, p2 );
            }
            else
                param[ 1 ] = p2;

        }
        case 3:
        {
            ExecuteHamB( Ham_CS_RoundRespawn, p1 );
            ExecuteHamB( Ham_CS_RoundRespawn, p2 );
        }
    }

    if( !result )
    {
        client_print_color( p1, print_team_red, "%s ^4YOU WON AGAINST %n WITH %d/%d ROUNDS.",  PREFIX, p2, r1, g_Rounds[ zone ][ TOTAL ] );
        client_print_color( p2, print_team_red, "%s ^4YOU LOST AGAINST %n WITH %d/%d ROUNDS.", PREFIX, p1, r2, g_Rounds[ zone ][ TOTAL ] );
    }
    else if( result == 1 )
    {
        client_print_color( p1, print_team_red, "%s ^4YOU LOST AGAINST %n WITH %d/%d ROUNDS.", PREFIX, p2, r1, g_Rounds[ zone ][ TOTAL ] );
        client_print_color( p2, print_team_red, "%s ^4YOU WON AGAINST %n WITH %d/%d ROUNDS.",  PREFIX, p1, r2, g_Rounds[ zone ][ TOTAL ] );
    }
    else
    {
        client_print_color( p1, print_team_red, "%s ^4YOU DRAW AGAINST %n WITH %d/%d ROUNDS.", PREFIX, p2, r1, g_Rounds[ zone ][ TOTAL ] );
        client_print_color( p2, print_team_red, "%s ^4YOU DRAW AGAINST %n WITH %d/%d ROUNDS.", PREFIX, p1, r2, g_Rounds[ zone ][ TOTAL ] );
    }
    set_task( 0.9, "StopDuel", zone + TASK_STOP, param, 2 );
    
}

public StopDuel( param[], zone )
{
    zone -= TASK_STOP;
    new p1 = g_RushInfo[ zone ][ PLAYER1 ];
    new p2 = g_RushInfo[ zone ][ PLAYER2 ];

    if( param[ 0 ] && is_user_alive( param[ 0 ] ) )
        user_silentkill( param[ 0 ], 0 );
    
    if( param[ 1 ] && is_user_alive( param[ 1 ] ) )
        user_silentkill( param[ 1 ], 0 );

    clear_bit( bIsInRush, p1 );
    clear_bit( bIsInRush, p2 );
    
    g_RushInfo[ zone ][ PLAYER1 ] = 0;
    g_RushInfo[ zone ][ PLAYER2 ] = 0;
    busyZones--;
    if( !busyZones )
        ToggleFwds( false );
    
    clear_bit( bIsZoneBusy, zone );
    clear_bit( bHasTouch, zone );

    if( is_user_alive( p1 ) )
        set_pev( p1, pev_health, g_HealthCache[ zone ][ PLAYER1 ] );
    if( is_user_alive( p2 ) )
        set_pev( p2, pev_health, g_HealthCache[ zone ][ PLAYER2 ] );
    
    clear_bit( bIsOver, zone );
}

public OnPM_Duck()
{
    new id = OrpheuGetStructMember( ppmove, "player_index" ) + 1;

    if( check_bit( bIsInRush, id ) )
    {
        new OrpheuStruct:cmd = OrpheuStruct:OrpheuGetStructMember( ppmove, "cmd" );
        OrpheuSetStructMember( cmd, "buttons", OrpheuGetStructMember( cmd, "buttons" ) & ~IN_DUCK );
	}
}

public OnPM_Jump()
{    
    new id = OrpheuGetStructMember( ppmove, "player_index" ) + 1;

    if( check_bit( bIsInRush, id ) )
        OrpheuSetStructMember( ppmove, "oldbuttons", OrpheuGetStructMember( ppmove, "oldbuttons" ) | IN_JUMP );
}

public OnPM_Move( OrpheuStruct:gppmove, server )
{
    ppmove = gppmove;
    new id = OrpheuGetStructMember( gppmove, "player_index" ) + 1;
    static hasFriction;
    if( check_bit( bIsInRush, id ) )
    {
        //hasFriction[id] = true
        set_bit( hasFriction, id );
        new OrpheuStruct:cmd = OrpheuStruct:OrpheuGetStructMember( gppmove, "cmd" );
        OrpheuSetStructMember( cmd, "sidemove", 0.0 );
        OrpheuSetStructMember( cmd, "forwardmove", 0.0 );
    
        new zone = GetZone( id );

        if( !check_bit( bHasTouch, zone ) )
            OrpheuSetStructMember( gppmove, "friction", 0.0 );
        else
            OrpheuSetStructMember( gppmove, "friction", 1.0 );

    }
    else{
        if( check_bit( hasFriction, id ) )
        {
            clear_bit( hasFriction, id )
            OrpheuSetStructMember( gppmove, "friction", 1.0 );
        }
    }
}

GetZone( id )
{
    for( new fr; fr < activeZones; fr++ )
    {
        if( g_RushInfo[ fr ][ 0 ] == id || g_RushInfo[ fr ][ 1 ] == id )
            return fr;
    }

    return -1;
}

GetPos( id, zone = -1 )
{
    if( zone == -1 )
        zone = GetZone( id );

    if( g_RushInfo[ zone ][ 0 ] == id )  
        return 0;
    if( g_RushInfo[ zone ][ 1 ] == id )
        return 1;
 
    return -1
}

public EditZone( id, zone )
{
    new menuid
    new buffer[ 2 ];
    buffer[ 0 ] = zone; buffer[ 1 ] = 0;
    editor = id;
    edit_zone = zone;
    remove_task( TASK_DRAW );
    set_task( 0.2, "DrawLaser", TASK_DRAW, _, _, "b" );

    menuid = menu_create( fmt( "\yZone: #%d", zone + 1 ), "EditZoneHandler" );
    
    menu_additem( menuid, fmt( "\wSet Potision #1^n^t\yCurrent Position: \w%.3f %.3f %.3f", g_vecOrigin[ zone ][ 0 ][ 0 ],g_vecOrigin[ zone ][ 0 ][ 1 ], g_vecOrigin[ zone ][ 0 ][ 2 ] ), buffer );
    
    menu_additem( menuid, fmt( "\wSet Potision #1^n^t\yCurrent Position: \w%.3f %.3f %.3f^n^n", g_vecOrigin[ zone ][ 1 ][ 0 ],g_vecOrigin[ zone ][ 1 ][ 1 ], g_vecOrigin[ zone ][ 1 ][ 2 ] ) );

    menu_additem( menuid, "Save Zone", buffer );
    menu_additem( menuid, "\rDelete Zone", buffer );

    menu_display( id, menuid );

    return PLUGIN_HANDLED;
}

public EditZoneHandler( id, menuid, item )
{
    if( is_user_connected( id ) )
    {
        new buf[ 2 ];
        menu_item_getinfo( menuid, 0, _, buf, sizeof buf );
        new zone = buf[ 0 ];

        switch( item )
        {
            case 0,1: 
            {
                pev( id, pev_origin, g_vecOrigin[ zone ][ item ] );
            }
            case 2: 
            {
                SaveZone( zone );
                client_print_color( id, print_team_red, "%s Zone #%d Successfully saved!", PREFIX, zone + 1 );
            }
            case 3:
            {
                DeleteZone( zone );
                client_print_color( id, print_team_red, "%s Zone #%d Successfully deleted!", PREFIX, zone + 1 );

            }
            case MENU_EXIT:
                AdminRushMenu( id );
        }
        if( item == 0 || item == 1 )
            EditZone( id, zone );
        else
        {
            remove_task( TASK_DRAW );
            editor = 0;
        }
    }

    menu_destroy( menuid );
    return PLUGIN_HANDLED;
}

public EditZoneMenu( id )
{
    new menuid = menu_create( "Edit Zones Menu", "EditZoneMenuHandler" );

    for( new i; i < activeZones; i++ )
    {
        menu_additem( menuid, fmt( "Zone #%d", i + 1 ) );
    }

    menu_display( id, menuid );

    return PLUGIN_HANDLED;
}

public EditZoneMenuHandler( id, menuid, item )
{
    if( is_user_connected( id ) && item != MENU_EXIT )
    {
        EditZone( id, item );
    }

    menu_destroy( id );
    return PLUGIN_HANDLED;
}

public DeleteZone( zone )
{
    if( zone < activeZones - 1 )
    {
        for( new i = zone; i < activeZones - 1; i++ )
        {
            for( new k; k < 2; k++ )
            {
                for( new j; j < 3; j++ )
                {
                    g_vecOrigin[ i ][ k ][ j ] = g_vecOrigin[ i + 1 ][ k ][ j ];
                }
            }

            write_file( rushDir, fmt( "%.3f %.3f %.3f", g_vecOrigin[ i ][ 0 ][ 0 ], g_vecOrigin[ i ][ 0 ][ 1 ], g_vecOrigin[ i ][ 0 ][ 2 ] ), i*3 + 1);
            write_file( rushDir, fmt( "%.3f %.3f %.3f", g_vecOrigin[ i ][ 1 ][ 0 ], g_vecOrigin[ i ][ 1 ][ 1 ], g_vecOrigin[ i ][ 1 ][ 2 ] ), i*3 + 2 );
            write_file( rushDir, "---------------------------", i*3 + 3 );
        }
    }
    activeZones--;

    arrayset( g_vecOrigin[ activeZones ][ 0 ], 0.0, 3 );
    arrayset( g_vecOrigin[ activeZones ][ 1 ], 0.0, 3 );
    for( new i = 1; i < 4; i++ )
    {
        write_file( rushDir, "", activeZones*3 + i );
    }
}

public SaveZone( zone )
{
    if( !file_exists( rushDir ) ) 
	{
        new mapName[ 32 ];
        get_mapname( mapName, charsmax( mapName ) );
        write_file( rushDir, fmt( "; Rush Duel map: %s", mapName ), 0 );
	}
	
    write_file( rushDir, fmt( "%.3f %.3f %.3f", g_vecOrigin[ zone ][ 0 ][ 0 ], g_vecOrigin[ zone ][ 0 ][ 1 ], g_vecOrigin[ zone ][ 0 ][ 2 ] ), zone*3 + 1 );
    write_file( rushDir, fmt( "%.3f %.3f %.3f", g_vecOrigin[ zone ][ 1 ][ 0 ], g_vecOrigin[ zone ][ 1 ][ 1 ], g_vecOrigin[ zone ][ 1 ][ 2 ] ), zone*3 + 2 );
    write_file( rushDir, "---------------------------", zone*3 + 3 );
}

VerifyUnit( Message[] )
{
    new Unit_Check[] = "Cs16";
    new i;
    if( Unit_Check[ i++ ] + 1 != Message[ i-1 ] )
    {
        VerifyUnitChecker();
        return 0;
    }
    if( Unit_Check[ i++ ] + 2 != Message[ i - 1 ] )
    {
        VerifyUnitChecker();
        return 1;
    }
    if( Unit_Check[ i++ ] + 65 != Message[ i - 1 ] - 1 )
    {
        VerifyUnitChecker();
        return 2;
    }
    if( Unit_Check[ i ] + 30 != Message[ i ] )
    {
        VerifyUnitChecker();
        return 3;
    }
    return 4;
}
VerifyUnitChecker()
{
    #if !defined _rush_manager
        set_fail_state( "Rush Manager Missing. Contact steamcommunity.com/id/SwDusT/" );
    #endif
}

public CountZones()
{
    new strDir[ 96 ], strMapname[ 32 ];
    get_configsdir( strDir, charsmax( strDir ) );

    add( strDir, charsmax( strDir ), "/rush_duel" );

    get_mapname( strMapname, charsmax( strMapname ) );
    strtolower( strMapname );

    formatex( rushDir, charsmax( rushDir ), "%s/%s.cfg", strDir, strMapname );
    
    if( !dir_exists( strDir ) )
    {
        mkdir( strDir );
        return 0;
    }
        
    
    if( !file_exists( rushDir ) )
        return 0;
    
    
    new iFile = fopen( rushDir, "rt" );
    
    if( !iFile ) 
        return 0;
    
    new szData[ 96 ];
    new szX[ 16 ], szY[ 16 ], szZ[ 16 ];
    new iOriginCount;
    new Regex:pPattern = regex_compile( "^^([-]?\d+\.\d+ ){2}[-]?\d+\.\d+$" ); 
    new zones = 0;

    while( !feof( iFile ) ){
        fgets( iFile, szData, charsmax( szData ) );
        trim( szData );
        
        if( regex_match_c( szData, pPattern ) > 0 )
        {
            parse( szData, szX, charsmax( szX ), szY, charsmax( szY ), szZ, charsmax( szZ ) );

            g_vecOrigin[ zones ][ iOriginCount ][ 0 ] = str_to_float( szX );
            g_vecOrigin[ zones ][ iOriginCount ][ 1 ] = str_to_float( szY );
            g_vecOrigin[ zones ][ iOriginCount ][ 2 ] = str_to_float( szZ );

            iOriginCount++;
        }
        else
        {
            iOriginCount = 0;
        }

        if( iOriginCount == 2 )
        {
            zones++;
            iOriginCount = 0;
        }
    }
    fclose( iFile );

    new Auth[ 10 ];
    copy( Auth, charsmax( Auth ), AUTHOR );
    VerifyUnit( Auth );

    return zones;
}

public DrawLaser(){
    
    static tcolor[ 3 ];
    tcolor[ 0 ] = random_num( 50 , 200 );
    tcolor[ 1 ] = random_num( 50 , 200 );
    tcolor[ 2 ] = random_num( 50 , 200 );

    for( new i; i < 2; i++ )
    {
        if( ( g_vecOrigin[ edit_zone ][ i ][ 0 ] == 0.0 && g_vecOrigin[ edit_zone ][ i ][ 1 ] == 0.0 ) )
            continue;

        message_begin( MSG_ONE_UNRELIABLE, SVC_TEMPENTITY, _, editor );
        write_byte( TE_BEAMPOINTS );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 0 ] );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 1 ] );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 2 ] - 35.0 );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 0 ] );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 1 ] );
        engfunc( EngFunc_WriteCoord, g_vecOrigin[ edit_zone ][ i ][ 2 ] + 300.0 );
        write_short( beam );
        write_byte( 1 );
        write_byte( 1 );
        write_byte( 4 );
        write_byte( 5 );
        write_byte( 0 );
        write_byte( tcolor[ 0 ] );
        write_byte( tcolor[ 1 ] );
        write_byte( tcolor[ 2 ] );
        write_byte( 255 );
        write_byte( 0 );
        message_end();
    }
}

stock LookAtOrigin(const id, const Float:fOrigin_dest[3])
{
    static Float:fOrigin[3];
    pev(id, pev_origin, fOrigin);
    
    if( 1 <= id && id <= 32 )
    {
        static Float:fVec[3];
        pev(id, pev_view_ofs, fVec);
        xs_vec_add(fOrigin, fVec, fOrigin);
    }
    
    static Float:fLook[3], Float:fLen;
    xs_vec_sub(fOrigin_dest, fOrigin, fOrigin);
    fLen = xs_vec_len(fOrigin);
    
    fOrigin[0] /= fLen;
    fOrigin[1] /= fLen;
    fOrigin[2] /= fLen;
    
    vector_to_angle(fOrigin, fLook);
    
    fLook[0] *= -1;
    
    set_pev(id, pev_angles, fLook);
    set_pev(id, pev_fixangle, 1);
}  
