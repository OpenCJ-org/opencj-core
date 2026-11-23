// Exercise production input notification state without a game server or scripts.
#include "../../cod4x-server/src/opencj_main.cpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>

serverStatic_t svs = {};
static gentity_t playerEntity = {};
static gclient_t playerClient = {};
static std::vector<int> arguments;
static int callbackCount;
static int releasedThreadCount;
static int checks;

static void check(bool passed, const char *scenario)
{
    ++checks;
    if (!passed)
    {
        std::fprintf(stderr, "ENGINE INPUT FAIL: %s\n", scenario);
        std::exit(1);
    }
}

void Scr_AddBool(bool value)
{
    arguments.push_back(value);
}

void Scr_AddInt(int value)
{
    arguments.push_back(value);
}

short Scr_ExecEntThread(gentity_t *entity, int callbackHook, unsigned int argumentCount)
{
    assert(entity == &playerEntity);
    assert(callbackHook == 41);
    assert(argumentCount == 4);
    ++callbackCount;
    return 7;
}

void Scr_FreeThread(short threadId)
{
    assert(threadId == 7);
    ++releasedThreadCount;
}

static void checkInputChanges()
{
    client_t *client = &svs.clients[0];
    client->gentity = &playerEntity;
    playerEntity.client = &playerClient;
    playerClient.ps.groundEntityNum = ENTITYNUM_NONE;
    opencj_callbacks[OPENCJ_CB_MOVEMENTSTATE] = 41;
    usercmd_t movementCommand = {};
    movementCommand.forwardmove = 127;
    movementCommand.rightmove = -127;
    movementCommand.serverTime = 1000;
    reportMovementInput(client, &movementCommand);
    check(arguments == std::vector<int>({0, 1000, -1, 1}),
          "initial notification pushes ground, time, right and forward in script order");
    check(callbackCount == 1 && releasedThreadCount == 1,
          "notification releases its script thread");

    arguments.clear();
    movementCommand.serverTime = 1004;
    reportMovementInput(client, &movementCommand);
    check(arguments.empty() && callbackCount == 1,
          "new command time alone does not repeat unchanged input");
    movementCommand.rightmove = 0;
    reportMovementInput(client, &movementCommand);
    check(arguments == std::vector<int>({0, 1004, 0, 1}),
          "releasing a direction produces a complete input notification");

    arguments.clear();
    playerClient.ps.groundEntityNum = 0;
    reportMovementInput(client, &movementCommand);
    check(arguments == std::vector<int>({1, 1004, 0, 1}), "ground contact change is reported");
    arguments.clear();
    opencj_invalidateMovementInput(0);
    reportMovementInput(client, &movementCommand);
    check(arguments == std::vector<int>({1, 1004, 0, 1}),
          "invalidation forces the next complete input state");

    arguments.clear();
    opencj_callbacks[OPENCJ_CB_MOVEMENTSTATE] = 0;
    movementCommand.forwardmove = 0;
    reportMovementInput(client, &movementCommand);
    check(arguments.empty() && opencj_historyInput[0].forwardDirection == 0,
          "missing callback still records the current input");
    opencj_callbacks[OPENCJ_CB_MOVEMENTSTATE] = 41;
    reportMovementInput(client, &movementCommand);
    check(arguments.empty(), "enabling a callback does not invent an input change");
    opencj_invalidateMovementInput(-1);
    opencj_invalidateMovementInput(MAX_CLIENTS);
    check(opencj_historyInputValid[0], "invalid client indices do not invalidate another client");
    check(callbackCount == releasedThreadCount, "every created callback thread was released");
}

int main()
{
    checkInputChanges();
    std::printf("ENGINE INPUT COMPLETE checks=%d\n", checks);
}
