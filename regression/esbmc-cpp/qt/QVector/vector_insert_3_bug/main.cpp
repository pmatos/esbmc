#include <QVector>
#include <cassert>

int main ()
{
    QVector<double> vector;
    vector << 2.718 << 1.442 << 0.4342;
    vector.insert(1, 3, 9.9);
    // vector: [2.718, 9.9, 9.9, 9.9, 1.442, 0.4342]

    assert( !(vector.size() == 6) );

  return 0;
}

