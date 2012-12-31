// set_unexpected example
#include <iostream>
#include <exception>
using namespace std;

void myfunction () {
  throw 1;   // throws char (not in exception-specification)
}

int main (void) {
  try {
    myfunction();
  }
  catch (int) { cerr << "caught int\n"; }
  catch (...) { cerr << "caught other exception (non-compliant compiler?)\n"; }
  return 0;
}
